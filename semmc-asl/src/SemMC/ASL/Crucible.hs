{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE TypeOperators #-}
-- | Convert fragments of ASL code into Crucible CFGs
module SemMC.ASL.Crucible (
    functionToCrucible
  , procedureToCrucible
  , FunctionSignature
  , funcSigRepr
  , funcArgReprs
  , funcGlobalReprs
  , ProcedureSignature
  , procSigBaseRepr
  , procSigArgReprs
  , procSigGlobals
  , procSigAssigned
  , procSigAssignedBase
  , procSigRepr
  , SomeSignature(..)
  , computeDefinitionSignature
  , computeInstructionSignature
  , Callable
  , asCallable
  , LabeledValue(..)
  , BaseGlobalVar(..)
  , Overrides(..)
  -- * Syntax extension
  , ASLExt
  , ASLApp(..)
  , ASLStmt
  , aslExtImpl
  -- * Exceptions
  , TranslationException(..)
  ) where

import           Control.Applicative ( (<|>) )
import qualified Control.Exception as X
import           Control.Monad ( when )
import           Control.Monad.ST ( stToIO )
import qualified Control.Monad.State.Class as MS
import           Data.Functor.Product ( Product(..) )
import           Data.Maybe ( fromMaybe )
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.NatRepr as NR
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Parameterized.TraversableFC as FC
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Lang.Crucible.CFG.Core as CCC
import qualified Lang.Crucible.CFG.Expr as CCE
import qualified Lang.Crucible.CFG.Generator as CCG
import qualified Lang.Crucible.CFG.SSAConversion as CCS
import qualified Lang.Crucible.FunctionHandle as CFH
import qualified Lang.Crucible.Types as CT
import           Unsafe.Coerce ( unsafeCoerce )
import qualified What4.BaseTypes as WT
import qualified What4.ProgramLoc as WP

import qualified Language.ASL.Syntax as AS

import           SemMC.ASL.Extension ( ASLExt, ASLApp(..), ASLStmt, aslExtImpl )
import           SemMC.ASL.Exceptions ( TranslationException(..) )
import           SemMC.ASL.Signature

data Callable = Callable { callableName :: AS.QualifiedIdentifier
                         , callableArgs :: [AS.SymbolDecl]
                         , callableRets :: [AS.Type]
                         , callableStmts :: [AS.Stmt]
                         }

asCallable :: AS.Definition -> Maybe Callable
asCallable def =
  case def of
    AS.DefCallable { AS.callableName = name
                   , AS.callableArgs = args
                   , AS.callableRets = rets
                   , AS.callableStmts = stmts
                   } ->
      Just Callable { callableName = name
                    , callableArgs = args
                    , callableRets = rets
                    , callableStmts = stmts
                    }
    _ -> Nothing

-- | Compute the signature for a definition
--
-- FIXME: This may need to take all of the signatures of called functions to compute its own
-- signature (since they might be procedures updating state that isn't obvious)
computeDefinitionSignature :: [(String, SomeSignature)] -> Callable -> IO SomeSignature
computeDefinitionSignature = undefined

computeInstructionSignature :: [(String, SomeSignature)] -> [AS.Stmt] -> IO SomeSignature
computeInstructionSignature = undefined

functionToCrucible :: (ret ~ CT.BaseToType tp)
                   => Overrides ASLExt
                   -> FunctionSignature init ret tp
                   -> CFH.FnHandle init ret
                   -> [AS.Stmt]
                   -> IO (CCC.SomeCFG ASLExt init ret)
functionToCrucible ov sig hdl stmts = do
  let pos = WP.InternalPos
  (CCG.SomeCFG cfg0, _) <- stToIO $ CCG.defineFunction pos hdl (funcDef ov sig stmts)
  return (CCS.toSSA cfg0)

funcDef :: (ret ~ CT.BaseToType tp)
        => Overrides ASLExt
        -> FunctionSignature init ret tp
        -> [AS.Stmt]
        -> Ctx.Assignment (CCG.Atom s) init
        -> (TranslationState ret s, CCG.Generator ASLExt h s (TranslationState ret) ret (CCG.Expr ASLExt s ret))
funcDef ov sig stmts args = (funcInitialState sig args, defineFunction ov sig stmts args)

funcInitialState :: forall init ret tp s
                  . FunctionSignature init ret tp
                 -> Ctx.Assignment (CCG.Atom s) init
                 -> TranslationState ret s
funcInitialState sig args =
  TranslationState m1 Map.empty (error "globals") (error "undefined") (error "unpredictable") (error "sigs")
  where
    m1 = Ctx.forIndex (Ctx.size args) addArgumentAtom Map.empty
    addArgumentAtom :: forall tp0
                     . Map.Map T.Text (Some (CCG.Atom s))
                    -> Ctx.Index init tp0
                    -> Map.Map T.Text (Some (CCG.Atom s))
    addArgumentAtom m idx =
      let atom = args Ctx.! idx
          LabeledValue argName _ = funcArgReprs sig Ctx.! idx
      in Map.insert argName (Some atom) m

newtype TypedName tp = TypedName T.Text

instance TestEquality TypedName where
  testEquality (TypedName t1) (TypedName t2)
    | t1 == t2 = Just (unsafeCoerce Refl)
    | otherwise = Nothing

instance OrdF TypedName where
  compareF (TypedName t1) (TypedName t2) = unsafeCoerce (fromOrdering (compare t1 t2))

-- Will track the mapping from (ASL) identifiers to Crucible Atoms
data TranslationState ret s =
  TranslationState { tsArgAtoms :: Map.Map T.Text (Some (CCG.Atom s))
                   -- ^ Atoms corresponding to function/procedure inputs.  We assume that these are
                   -- immutable and allocated before we start executing.
                   , tsVarRefs :: Map.Map T.Text (Some (CCG.Reg s))
                   -- ^ Local registers containing values; these are created on first use
                   , tsGlobals :: Map.Map T.Text (Some CCG.GlobalVar)
                   -- ^ Global variables corresponding to machine state (e.g., machine registers).
                   -- These are allocated before we start executing based on the list of
                   -- transitively-referenced globals in the signature.
                   , tsUndefinedVar :: CCG.GlobalVar CT.BoolType
                   -- ^ A variable that starts as False, but transitions to True when an instruction
                   -- triggers undefined behavior
                   , tsUnpredictableVar :: CCG.GlobalVar CT.BoolType
                   -- ^ A variable that starts as False, but transitions to True when an instruction
                   -- triggers unpredictable behavior
                   , tsFunctionSigs :: Map.Map T.Text SomeSignature
                   -- ^ A collection of all of the signatures of defined functions (both functions
                   -- and procedures)
                   }

data ExprConstructor ext h s ret where
  ExprConstructor :: a tp
                  -> (a tp -> CCG.Generator ext h s (TranslationState ret) ret (CCG.Expr ext s tp))
                  -> ExprConstructor ext h s ret

lookupVarRef :: forall ext h s ret
              . (CCE.IsSyntaxExtension ext)
             => T.Text
             -> CCG.Generator ext h s (TranslationState ret) ret (Some (CCG.Expr ext s))
lookupVarRef name = do
  ts <- MS.get
  let err = X.throw (UnboundName name)
  case fromMaybe err (lookupArg ts <|> lookupRef ts <|> lookupGlobal ts) of
    ExprConstructor e con -> Some <$> con e
  where
    lookupArg ts = do
      Some e <- Map.lookup name (tsArgAtoms ts)
      return (ExprConstructor (CCG.AtomExpr e) return)
    lookupRef ts = do
      Some r <- Map.lookup name (tsVarRefs ts)
      return (ExprConstructor r CCG.readReg)
    lookupGlobal ts = do
      Some g <- Map.lookup name (tsGlobals ts)
      return (ExprConstructor g CCG.readGlobal)

data Overrides ext =
  Overrides { overrideStmt :: forall h s ret . AS.Stmt -> Maybe (CCG.Generator ext h s (TranslationState ret) ret ())
            , overrideExpr :: forall h s ret . AS.Expr -> Maybe (CCG.Generator ext h s (TranslationState ret) ret (Some (CCG.Atom s)))
            }

defineFunction :: forall ret tp init h s
                . (ret ~ CT.BaseToType tp)
               => Overrides ASLExt
               -> FunctionSignature init ret tp
               -> [AS.Stmt]
               -> Ctx.Assignment (CCG.Atom s) init
               -> CCG.Generator ASLExt h s (TranslationState ret) ret (CCG.Expr ASLExt s ret)
defineFunction ov sig stmts args = do
  mapM_ (translateStatement ov (CT.baseToType (funcSigRepr sig))) stmts
  -- Note: we shouldn't actually get here, as we should have called returnFromFunction while
  -- translating.
  X.throw (NoReturnInFunction (SomeFunctionSignature sig))


translateStatement :: Overrides ASLExt
                   -> CT.TypeRepr ret
                   -> AS.Stmt
                   -> CCG.Generator ASLExt h s (TranslationState ret) ret ()
translateStatement ov rep stmt
  | Just so <- overrideStmt ov stmt = so
  | otherwise =
    case stmt of
      AS.StmtReturn Nothing
        | Just Refl <- testEquality rep CT.UnitRepr -> CCG.returnFromFunction (CCG.App CCE.EmptyApp)
        | otherwise -> X.throw (InvalidReturnType CT.UnitRepr)
      AS.StmtReturn (Just expr) -> do
        Some a <- translateExpr ov expr
        Refl <- assertAtomType expr rep a
        CCG.returnFromFunction (CCG.AtomExpr a)
      AS.StmtIf clauses melse -> translateIf ov rep clauses melse
      AS.StmtAssert e -> do
        Some atom <- translateExpr ov e
        Refl <- assertAtomType e CT.BoolRepr atom
        let msg = CCG.App (CCE.TextLit (T.pack (show e)))
        CCG.assertExpr (CCG.AtomExpr atom) msg
      AS.StmtVarsDecl ty idents -> mapM_ (declareUndefinedVar ty) idents
      AS.StmtVarDeclInit (ident, ty) expr -> translateDefinedVar ov ty ident expr
      AS.StmtConstDecl (ident, ty) expr ->
        -- NOTE: We use the same translation for constants.  We don't do any verification that the
        -- ASL doesn't attempt to modify a constant.
        translateDefinedVar ov ty ident expr
      AS.StmtAssign lval expr -> translateAssignment ov lval expr
      AS.StmtWhile test body -> do
        let testG = do
              Some testA <- translateExpr ov test
              Refl <- assertAtomType test CT.BoolRepr testA
              return (CCG.AtomExpr testA)
        let bodyG = mapM_ (translateStatement ov rep) body
        CCG.while (WP.InternalPos, testG) (WP.InternalPos, bodyG)
      AS.StmtRepeat body test -> translateRepeat ov rep body test
      AS.StmtFor var (lo, hi) body -> translateFor ov rep var lo hi body
      AS.StmtUndefined -> do
        gv <- MS.gets tsUndefinedVar
        CCG.writeGlobal gv (CCG.App (CCE.BoolLit True))
      AS.StmtUnpredictable -> do
        gv <- MS.gets tsUnpredictableVar
        CCG.writeGlobal gv (CCG.App (CCE.BoolLit True))
      AS.StmtCall qi@(AS.QualifiedIdentifier _ ident) args -> do
        sigMap <- MS.gets tsFunctionSigs
        case Map.lookup ident sigMap of
          Nothing -> X.throw (MissingFunctionDefinition ident)
          Just (SomeFunctionSignature _) -> X.throw (ExpectedProcedureSignature ident)
          Just (SomeProcedureSignature sig) -> do
            argAtoms <- mapM (translateExpr ov) args
            case assignmentFromList (Some Ctx.empty) argAtoms of
              Some argAssign -> do
                let atomTypes = FC.fmapFC CCG.typeOfAtom argAssign
                let expectedTypes = FC.fmapFC projectValue (procSigArgReprs sig)
                if | Just Refl <- testEquality atomTypes expectedTypes -> do
                       let vals = FC.fmapFC CCG.AtomExpr argAssign
                       -- Some retRep <- procBaseRep (AS.ExprCall qi args) sig
                       -- let uf = UF ident (WT.BaseStructRepr retRep) atomTypes vals
                       let uf = UF ident (procSigBaseRepr sig) atomTypes vals
                       atom <- CCG.mkAtom (CCG.App (CCE.ExtensionApp uf))
                       return ()
                   | otherwise -> X.throw (InvalidArgumentTypes ident atomTypes)

-- procBaseRep :: AS.Expr
--             -> ProcedureSignature init ret0 tps
--             -> CCG.Generator ASLExt h s (TranslationState ret) ret (Some (Ctx.Assignment WT.BaseTypeRepr))
-- procBaseRep e sig = do
--   baseTypes <- mapM (assertAsBaseType e) (FC.toListFC Some (procSigRepr sig))
--   return (assignmentFromList (Some Ctx.empty) baseTypes)

assertAsBaseType :: (Monad m) => AS.Expr -> Some BaseGlobalVar -> m (Some WT.BaseTypeRepr)
assertAsBaseType e (Some gv) =
  case CT.asBaseType (CCG.globalType (unBaseVar gv)) of
    -- This isn't really an expr, but this is good enough
    CT.NotBaseType -> X.throw (ExpectedBaseType e (CCG.globalType (unBaseVar gv)))
    CT.AsBaseType btr -> return (Some btr)

-- | Translate a for statement into Crucible
--
-- The translation is from
--
-- > for i = X to Y
-- >    body
--
-- to
--
-- > i = X
-- > while(i <= Y)
-- >   body
-- >   i = i + 1
--
-- NOTE: The translation is inclusive of the upper bound - is that right?
--
-- NOTE: We are assuming that the variable assignment is actually a declaration of integer type
translateFor :: Overrides ASLExt
             -> CT.TypeRepr ret
             -> AS.Identifier
             -> AS.Expr
             -> AS.Expr
             -> [AS.Stmt]
             -> CCG.Generator ASLExt h s (TranslationState ret) ret ()
translateFor ov rep var lo hi body = do
  let ty = AS.TypeRef (AS.QualifiedIdentifier AS.ArchQualAny (T.pack "integer"))
  translateDefinedVar ov ty var lo
  let testG = do
        let ident = AS.QualifiedIdentifier AS.ArchQualAny var
        let testE = AS.ExprBinOp AS.BinOpLTEQ (AS.ExprVarRef ident) hi
        Some testA <- translateExpr ov testE
        Refl <- assertAtomType testE CT.BoolRepr testA
        return (CCG.AtomExpr testA)
  let bodyG = mapM_ (translateStatement ov rep) body
  CCG.while (WP.InternalPos, testG) (WP.InternalPos, bodyG)


translateRepeat :: Overrides ASLExt
                -> CT.TypeRepr ret
                -> [AS.Stmt]
                -> AS.Expr
                -> CCG.Generator ASLExt h s (TranslationState ret) ret ()
translateRepeat ov rtp body test = do
  cond_lbl <- CCG.newLabel
  loop_lbl <- CCG.newLabel
  exit_lbl <- CCG.newLabel

  CCG.defineBlock loop_lbl $ do
    mapM_ (translateStatement ov rtp) body
    CCG.jump cond_lbl

  CCG.defineBlock cond_lbl $ do
    Some testA <- translateExpr ov test
    Refl <- assertAtomType test CT.BoolRepr testA
    CCG.branch (CCG.AtomExpr testA) loop_lbl exit_lbl

  CCG.continue exit_lbl (CCG.jump loop_lbl)

translateDefinedVar :: Overrides ASLExt
                    -> AS.Type
                    -> AS.Identifier
                    -> AS.Expr
                    -> CCG.Generator ASLExt h s (TranslationState ret) ret ()
translateDefinedVar ov ty ident expr =
  case translateType ty of
    Some expected -> do
      Some atom <- translateExpr ov expr
      Refl <- assertAtomType expr expected atom
      locals <- MS.gets tsVarRefs
      when (Map.member ident locals) $ do
        X.throw (LocalAlreadyDefined ident)
      reg <- CCG.newReg (CCG.AtomExpr atom)
      MS.modify' $ \s -> s { tsVarRefs = Map.insert ident (Some reg) locals }

-- | Translate general assignment statements into Crucible
--
-- This case is interesting, as assignments can be to locals or globals.
--
-- NOTE: We are assuming that there cannot be assignments to arguments.
translateAssignment :: Overrides ASLExt
                    -> AS.LValExpr
                    -> AS.Expr
                    -> CCG.Generator ASLExt h s (TranslationState ret) ret ()
translateAssignment ov lval e = do
  Some atom <- translateExpr ov e
  case lval of
    AS.LValIgnore -> return () -- Totally ignore - this probably shouldn't happen (except inside of a tuple)
    AS.LValVarRef (AS.QualifiedIdentifier _ ident) -> do
      locals <- MS.gets tsVarRefs
      case Map.lookup ident locals of
        Just (Some lreg) -> do
          Refl <- assertAtomType e (CCG.typeOfReg lreg) atom
          CCG.assignReg lreg (CCG.AtomExpr atom)
        Nothing -> do
          globals <- MS.gets tsGlobals
          case Map.lookup ident globals of
            Just (Some gv) -> do
              Refl <- assertAtomType e (CCG.globalType gv) atom
              CCG.writeGlobal gv (CCG.AtomExpr atom)
            Nothing -> X.throw (UnboundName ident)

-- | Put a new local in scope and initialize it to an undefined value
declareUndefinedVar :: (CCE.IsSyntaxExtension ext)
                    => AS.Type
                    -> AS.Identifier
                    -> CCG.Generator ext h s (TranslationState ret) ret ()
declareUndefinedVar ty ident = do
  locals <- MS.gets tsVarRefs
  when (Map.member ident locals) $ do
    X.throw (LocalAlreadyDefined ident)
  case translateType ty of
    Some rep -> do
      reg <- CCG.newUnassignedReg rep
      MS.modify' $ \s -> s { tsVarRefs = Map.insert ident (Some reg) locals }

translateType :: AS.Type -> Some CT.TypeRepr
translateType = error "translateType unimplemented"

translateIf :: Overrides ASLExt
            -> CT.TypeRepr ret
            -> [(AS.Expr, [AS.Stmt])]
            -> Maybe [AS.Stmt]
            -> CCG.Generator ASLExt h s (TranslationState ret) ret ()
translateIf ov rep clauses melse =
  case clauses of
    [] -> mapM_ (translateStatement ov rep) (fromMaybe [] melse)
    (cond, body) : rest -> do
      Some condAtom <- translateExpr ov cond
      Refl <- assertAtomType cond CT.BoolRepr condAtom
      let genThen = mapM_ (translateStatement ov rep) body
      let genElse = translateIf ov rep rest melse
      CCG.ifte_ (CCG.AtomExpr condAtom) genThen genElse

assertAtomType :: AS.Expr
               -- ^ Expression that was translated
               -> CT.TypeRepr tp1
               -- ^ Expected type
               -> CCG.Atom s tp2
               -- ^ Translation (which contains the actual type)
               -> CCG.Generator ext h s (TranslationState ret) ret (tp1 :~: tp2)
assertAtomType expr expectedRepr atom =
  case testEquality expectedRepr (CCG.typeOfAtom atom) of
    Nothing -> X.throw (UnexpectedExprType expr (CCG.typeOfAtom atom) expectedRepr)
    Just Refl -> return Refl

-- | Translate an ASL expression into an Atom (which is a reference to an immutable value)
--
-- Atoms may be written to registers, which are mutable locals
translateExpr :: Overrides ASLExt
              -> AS.Expr
              -> CCG.Generator ASLExt h s (TranslationState ret) ret (Some (CCG.Atom s))
translateExpr ov expr
  | Just eo <- overrideExpr ov expr = eo
  | otherwise =
    case expr of
      AS.ExprLitInt i -> Some <$> CCG.mkAtom (CCG.App (CCE.IntLit i))
      AS.ExprLitBin bits -> do
        let nBits = length bits
        case NR.mkNatRepr (fromIntegral nBits) of
          Some nr
            | Just NR.LeqProof <- NR.testLeq (NR.knownNat @1) nr ->
              Some <$> CCG.mkAtom (CCG.App (CCE.BVLit nr (bitsToInteger bits)))
            | otherwise -> X.throw InvalidZeroLengthBitvector
      AS.ExprVarRef (AS.QualifiedIdentifier _ ident) -> do
        Some e <- lookupVarRef ident
        Some <$> CCG.mkAtom e
      AS.ExprLitReal {} -> X.throw (UnsupportedExpr expr)
      AS.ExprLitString {} -> X.throw (UnsupportedExpr expr)
      AS.ExprUnOp op expr' -> translateUnaryOp ov op expr'
      AS.ExprBinOp op e1 e2 -> translateBinaryOp ov op e1 e2
      AS.ExprTuple exprs -> do
        atoms <- mapM (translateExpr ov) exprs
        case assignmentFromList (Some Ctx.empty) atoms of
          Some asgn -> do
            let reprs = FC.fmapFC CCG.typeOfAtom asgn
            Some <$> CCG.mkAtom (CCG.App (CCE.MkStruct reprs (FC.fmapFC CCG.AtomExpr asgn)))
      AS.ExprInSet e elts -> do
        Some atom <- translateExpr ov e
        when (null elts) $ X.throw (EmptySetElementList expr)
        preds <- mapM (translateSetElementTest ov expr atom) elts
        Some <$> CCG.mkAtom (foldr disjoin (CCG.App (CCE.BoolLit False)) preds)
      AS.ExprIf clauses elseExpr -> translateIfExpr ov expr clauses elseExpr
      AS.ExprCall (AS.QualifiedIdentifier _ ident) args -> do
        sigMap <- MS.gets tsFunctionSigs
        case Map.lookup ident sigMap of
          Nothing -> X.throw (MissingFunctionDefinition ident)
          Just (SomeProcedureSignature _) -> X.throw (ExpectedFunctionSignature ident)
          Just (SomeFunctionSignature sig) -> do
            argAtoms <- mapM (translateExpr ov) args
            case assignmentFromList (Some Ctx.empty) argAtoms of
              Some argAssign -> do
                let atomTypes = FC.fmapFC CCG.typeOfAtom argAssign
                let expectedTypes = FC.fmapFC projectValue (funcArgReprs sig)
                if | Just Refl <- testEquality atomTypes expectedTypes -> do
                       let vals = FC.fmapFC CCG.AtomExpr argAssign
                       let uf = UF ident (funcSigRepr sig) atomTypes vals
                       Some <$> CCG.mkAtom (CCG.App (CCE.ExtensionApp uf))
                   | otherwise -> X.throw (InvalidArgumentTypes ident atomTypes)

-- | Translate the expression form of a conditional into a Crucible atom
translateIfExpr :: Overrides ASLExt
                -> AS.Expr
                -> [(AS.Expr, AS.Expr)]
                -> AS.Expr
                -> CCG.Generator ASLExt h s (TranslationState ret) ret (Some (CCG.Atom s))
translateIfExpr ov orig clauses elseExpr =
  case clauses of
    [] -> X.throw (MalformedConditionalExpression orig)
    [(test, res)] -> do
      Some testA <- translateExpr ov test
      Some resA <- translateExpr ov res
      Some elseA <- translateExpr ov elseExpr
      Refl <- assertAtomType test CT.BoolRepr testA
      Refl <- assertAtomType res (CCG.typeOfAtom elseA) resA
      case CT.asBaseType (CCG.typeOfAtom elseA) of
        CT.NotBaseType -> X.throw (ExpectedBaseType orig (CCG.typeOfAtom elseA))
        CT.AsBaseType btr ->
          Some <$> CCG.mkAtom (CCG.App (CCE.BaseIte btr (CCG.AtomExpr testA) (CCG.AtomExpr resA) (CCG.AtomExpr elseA)))
    (test, res) : rest -> do
      Some trA <- translateIfExpr ov orig rest elseExpr
      Some testA <- translateExpr ov test
      Some resA <- translateExpr ov res
      Refl <- assertAtomType test CT.BoolRepr testA
      Refl <- assertAtomType res (CCG.typeOfAtom trA) resA
      case CT.asBaseType (CCG.typeOfAtom trA) of
        CT.NotBaseType -> X.throw (ExpectedBaseType orig (CCG.typeOfAtom trA))
        CT.AsBaseType btr ->
          Some <$> CCG.mkAtom (CCG.App (CCE.BaseIte btr (CCG.AtomExpr testA) (CCG.AtomExpr resA) (CCG.AtomExpr trA)))

-- | Translate set element tests
--
-- Single element tests are translated into a simple equality test
--
-- Ranges are translated as a conjunction of inclusive tests. x IN [5..10] => 5 <= x && x <= 10
translateSetElementTest :: Overrides ASLExt
                        -> AS.Expr
                        -> CCG.Atom s tp
                        -> AS.SetElement
                        -> CCG.Generator ASLExt h s (TranslationState ret) ret (CCG.Expr ASLExt s CT.BoolType)
translateSetElementTest ov e0 a0 elt =
  case elt of
    AS.SetEltSingle expr -> do
      Some atom1 <- translateExpr ov expr
      Refl <- assertAtomType expr (CCG.typeOfAtom a0) atom1
      Some atom2 <- applyBinOp eqOp (e0, a0) (expr, atom1)
      Refl <- assertAtomType expr CT.BoolRepr atom2
      return (CCG.AtomExpr atom2)
    AS.SetEltRange lo hi -> do
      Some loA <- translateExpr ov lo
      Some hiA <- translateExpr ov hi
      Refl <- assertAtomType lo (CCG.typeOfAtom a0) loA
      Refl <- assertAtomType hi (CCG.typeOfAtom a0) hiA
      Some loTest <- applyBinOp leOp (lo, loA) (e0, a0)
      Some hiTest <- applyBinOp leOp (e0, a0) (hi, hiA)
      Refl <- assertAtomType lo CT.BoolRepr loTest
      Refl <- assertAtomType hi CT.BoolRepr hiTest
      return (CCG.App (CCE.And (CCG.AtomExpr loTest) (CCG.AtomExpr hiTest)))



disjoin :: (CCE.IsSyntaxExtension ext)
        => CCG.Expr ext s CT.BoolType
        -> CCG.Expr ext s CT.BoolType
        -> CCG.Expr ext s CT.BoolType
disjoin p1 p2 = CCG.App (CCE.Or p1 p2)

translateBinaryOp :: forall h s ret
                   . Overrides ASLExt
                  -> AS.BinOp
                  -> AS.Expr
                  -> AS.Expr
                  -> CCG.Generator ASLExt h s (TranslationState ret) ret (Some (CCG.Atom s))
translateBinaryOp ov op e1 e2 = do
  Some a1 <- translateExpr ov e1
  Some a2 <- translateExpr ov e2
  let p1 = (e1, a1)
  let p2 = (e2, a2)
  case op of
    AS.BinOpPlusPlus -> X.throw (UnsupportedBinaryOperator op)
    AS.BinOpLogicalAnd -> logicalBinOp CCE.And p1 p2
    AS.BinOpLogicalOr -> logicalBinOp CCE.Or p1 p2
    AS.BinOpBitwiseOr -> bvBinOp CCE.BVOr p1 p2
    AS.BinOpBitwiseAnd -> bvBinOp CCE.BVAnd p1 p2
    AS.BinOpBitwiseXor -> bvBinOp CCE.BVXor p1 p2
    AS.BinOpEQ -> applyBinOp eqOp p1 p2
    AS.BinOpNEQ -> do
      Some atom <- applyBinOp eqOp p1 p2
      Refl <- assertAtomType (AS.ExprBinOp op e1 e2) CT.BoolRepr atom
      Some <$> CCG.mkAtom (CCG.App (CCE.Not (CCG.AtomExpr atom)))
    AS.BinOpGT -> do
      -- NOTE: We always use unsigned comparison for bitvectors - is that correct?
      Some atom <- applyBinOp leOp p1 p2
      Refl <- assertAtomType (AS.ExprBinOp op e1 e2) CT.BoolRepr atom
      Some <$> CCG.mkAtom (CCG.App (CCE.Not (CCG.AtomExpr atom)))
    AS.BinOpLTEQ -> applyBinOp leOp p1 p2
    AS.BinOpLT -> applyBinOp ltOp p1 p2
    AS.BinOpGTEQ -> do
      Some atom <- applyBinOp ltOp p1 p2
      Refl <- assertAtomType (AS.ExprBinOp op e1 e2) CT.BoolRepr atom
      Some <$> CCG.mkAtom (CCG.App (CCE.Not (CCG.AtomExpr atom)))
    AS.BinOpAdd -> applyBinOp addOp p1 p2
    AS.BinOpSub -> applyBinOp subOp p1 p2
    AS.BinOpMul -> applyBinOp mulOp p1 p2
    AS.BinOpMod -> applyBinOp modOp p1 p2
    AS.BinOpShiftLeft -> bvBinOp CCE.BVShl p1 p2
    AS.BinOpShiftRight -> bvBinOp CCE.BVLshr p1 p2
    -- FIXME: What is the difference between BinOpDiv and BinOpDivide?

-- Arithmetic operators

addOp :: BinaryOperatorBundle ext s 'SameK
addOp = BinaryOperatorBundle CCE.BVAdd CCE.NatAdd CCE.IntAdd

subOp :: BinaryOperatorBundle ext s 'SameK
subOp = BinaryOperatorBundle CCE.BVSub CCE.NatSub CCE.IntSub

mulOp :: BinaryOperatorBundle ext s 'SameK
mulOp = BinaryOperatorBundle CCE.BVMul CCE.NatMul CCE.IntMul

modOp :: BinaryOperatorBundle ext s 'SameK
modOp = BinaryOperatorBundle (error "BV mod not supported") CCE.NatMod CCE.IntMod

-- Comparison operators

eqOp :: BinaryOperatorBundle ext s 'BoolK
eqOp = BinaryOperatorBundle CCE.BVEq CCE.NatEq CCE.IntEq

leOp :: BinaryOperatorBundle ext s 'BoolK
leOp = BinaryOperatorBundle CCE.BVUle CCE.NatLe CCE.IntLe

ltOp :: BinaryOperatorBundle ext s 'BoolK
ltOp = BinaryOperatorBundle CCE.BVUlt CCE.NatLt CCE.IntLt


data ReturnK = BoolK
             -- ^ Tag used for comparison operations, which always return BoolType
             | SameK
             -- ^ Tag used for other operations, which preserve the type

type family BinaryOperatorReturn (r :: ReturnK) (tp :: CT.CrucibleType) where
  BinaryOperatorReturn 'BoolK tp = CT.BoolType
  BinaryOperatorReturn 'SameK tp = tp

data BinaryOperatorBundle ext s (rtp :: ReturnK) =
  BinaryOperatorBundle { obBV :: forall n . (1 WT.<= n) => WT.NatRepr n -> CCG.Expr ext s (CT.BVType n) -> CCG.Expr ext s (CT.BVType n) -> CCE.App ext (CCG.Expr ext s) (BinaryOperatorReturn rtp (CT.BVType n))
                       , obNat :: CCG.Expr ext s CT.NatType -> CCG.Expr ext s CT.NatType -> CCE.App ext (CCG.Expr ext s) (BinaryOperatorReturn rtp CT.NatType)
                       , obInt :: CCG.Expr ext s CT.IntegerType -> CCG.Expr ext s CT.IntegerType -> CCE.App ext (CCG.Expr ext s) (BinaryOperatorReturn rtp CT.IntegerType)
                       }

-- | Apply a binary operator to two operands, performing the necessary type checks
applyBinOp :: (CCE.IsSyntaxExtension ext)
           => BinaryOperatorBundle ext s rtp
           -> (AS.Expr, CCG.Atom s tp1)
           -> (AS.Expr, CCG.Atom s tp2)
           -> CCG.Generator ext h s (TranslationState ret) ret (Some (CCG.Atom s))
applyBinOp bundle (e1, a1) (e2, a2) =
  case CCG.typeOfAtom a1 of
    CT.BVRepr nr -> do
      Refl <- assertAtomType e2 (CT.BVRepr nr) a2
      Some <$> CCG.mkAtom (CCG.App (obBV bundle nr (CCG.AtomExpr a1) (CCG.AtomExpr a2)))
    CT.NatRepr -> do
      Refl <- assertAtomType e2 CT.NatRepr a2
      Some <$> CCG.mkAtom (CCG.App (obNat bundle (CCG.AtomExpr a1) (CCG.AtomExpr a2)))
    CT.IntegerRepr ->do
      Refl <- assertAtomType e2 CT.IntegerRepr a2
      Some <$> CCG.mkAtom (CCG.App (obInt bundle (CCG.AtomExpr a1) (CCG.AtomExpr a2)))
    _ -> X.throw (UnsupportedComparisonType e1 (CCG.typeOfAtom a1))

bvBinOp :: (CCE.IsSyntaxExtension ext)
        => (forall n . (1 WT.<= n) => WT.NatRepr n -> CCG.Expr ext s (CT.BVType n) -> CCG.Expr ext s (CT.BVType n) -> CCE.App ext (CCG.Expr ext s) (CT.BVType n))
        -> (AS.Expr, CCG.Atom s tp1)
        -> (AS.Expr, CCG.Atom s tp2)
        -> CCG.Generator ext h s (TranslationState ret) ret (Some (CCG.Atom s))
bvBinOp con (e1, a1) (e2, a2) =
  case CCG.typeOfAtom a1 of
    CT.BVRepr nr -> do
      Refl <- assertAtomType e2 (CT.BVRepr nr) a2
      Some <$> CCG.mkAtom (CCG.App (con nr (CCG.AtomExpr a1) (CCG.AtomExpr a2)))
    _ -> X.throw (ExpectedBVType e1 (CCG.typeOfAtom a1))

logicalBinOp :: (CCE.IsSyntaxExtension ext)
             => (CCG.Expr ext s CT.BoolType -> CCG.Expr ext s CT.BoolType -> CCE.App ext (CCG.Expr ext s) CT.BoolType)
             -> (AS.Expr, CCG.Atom s tp1)
             -> (AS.Expr, CCG.Atom s tp2)
             -> CCG.Generator ext h s (TranslationState ret) ret (Some (CCG.Atom s))
logicalBinOp con (e1, a1) (e2, a2) = do
  Refl <- assertAtomType e1 CT.BoolRepr a1
  Refl <- assertAtomType e2 CT.BoolRepr a2
  Some <$> CCG.mkAtom (CCG.App (con (CCG.AtomExpr a1) (CCG.AtomExpr a2)))


assignmentFromList :: Some (Ctx.Assignment a) -> [Some a] -> Some (Ctx.Assignment a)
assignmentFromList (Some asgn0) elts =
  case elts of
    [] -> Some asgn0
    Some elt : rest -> assignmentFromList (Some (Ctx.extend asgn0 elt)) rest

translateUnaryOp :: Overrides ASLExt
                 -> AS.UnOp
                 -> AS.Expr
                 -> CCG.Generator ASLExt h s (TranslationState ret) ret (Some (CCG.Atom s))
translateUnaryOp ov op expr = do
  Some atom <- translateExpr ov expr
  case op of
    AS.UnOpNot -> do
      Refl <- assertAtomType expr CT.BoolRepr atom
      Some <$> CCG.mkAtom (CCG.App (CCE.Not (CCG.AtomExpr atom)))
    AS.UnOpNeg ->
      case CCG.typeOfAtom atom of
        CT.BVRepr nr -> do
          Some <$> CCG.mkAtom (CCG.App (CCE.BVNot nr (CCG.AtomExpr atom)))
        _ -> X.throw (ExpectedBVType expr (CCG.typeOfAtom atom))


bitsToInteger :: [Bool] -> Integer
bitsToInteger = undefined

procedureToCrucible :: Overrides ASLExt
                    -> ProcedureSignature init ret tps
                    -> CFH.FnHandle init ret
                    -> [AS.Stmt]
                    -> IO (CCC.SomeCFG ASLExt init ret)
procedureToCrucible ov sig hdl stmts = do
  let pos = WP.InternalPos
  (CCG.SomeCFG cfg0, _) <- stToIO $ CCG.defineFunction pos hdl (procDef ov sig stmts)
  return (CCS.toSSA cfg0)

procDef :: Overrides ASLExt
        -> ProcedureSignature init ret tp
        -> [AS.Stmt]
        -> Ctx.Assignment (CCG.Atom s) init
        -> (TranslationState ret s, CCG.Generator ASLExt h s (TranslationState ret) ret (CCG.Expr ASLExt s ret))
procDef ov sig stmts args =
  (procInitialState sig args, defineProcedure ov sig stmts args)

procInitialState :: ProcedureSignature init ret tp
                 -> Ctx.Assignment (CCG.Atom s) init
                 -> TranslationState ret s
procInitialState = undefined

defineProcedure :: Overrides ASLExt
                -> ProcedureSignature init ret tp
                -> [AS.Stmt]
                -> Ctx.Assignment (CCG.Atom s) init
                -> CCG.Generator ASLExt h s (TranslationState ret) ret (CCG.Expr ASLExt s ret)
defineProcedure ov sig stmts args = do
  mapM_ (translateStatement ov (error "ret type")) stmts
  -- Read all of the globals in the signature to produce a struct expr
  -- typedVals <- FC.traverseFC readTypedGlobal (procSigRepr sig)
  -- let reprs = FC.fmapFC fstFC typedVals
  -- let vals = FC.fmapFC sndFC typedVals
  -- return (CCG.App (CCE.MkStruct reprs vals))
  return undefined

-- fstFC :: Product a b tp -> a tp
-- fstFC (Pair a _) = a

-- sndFC :: Product a b tp -> b tp
-- sndFC (Pair _ b) = b

-- readTypedGlobal :: BaseGlobalVar bt
--                 -> CCG.Generator ext h s (TranslationState ret) ret (Product CT.TypeRepr (CCG.Expr ext s) (CT.BaseToType bt))
-- readTypedGlobal = undefined
