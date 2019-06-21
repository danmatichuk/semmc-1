{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module ParamFormulaTests where

import qualified Control.Monad.Catch as E
import           Control.Monad.IO.Class ( liftIO )
import           Data.Maybe
import           Data.Parameterized.Classes
import qualified Data.Parameterized.HasRepr as HR
import qualified Data.Parameterized.List as SL
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.Nonce
import           Data.Parameterized.Some
import qualified Data.Set as Set
import           Hedgehog
import           Hedgehog.Internal.Property ( forAllT )
import           HedgehogUtil ( )
import qualified Lang.Crucible.Backend.Online as CBO
import           Lang.Crucible.Backend.Simple ( newSimpleBackend )
import qualified SemMC.BoundVar as BV
import qualified SemMC.Formula.Formula as SF
import qualified SemMC.Formula.Parser as FI
import qualified SemMC.Formula.Printer as FO
import qualified SemMC.Log as Log
import           Test.Tasty
import           Test.Tasty.Hedgehog
import           TestArch
import           TestArchPropGen
import           TestUtils
import           What4.BaseTypes

import           Prelude


parameterizedFormulaTests :: [TestTree]
parameterizedFormulaTests = [
  testGroup "Parameterized Formulas" $

    [ testProperty "parameter type" $
      property $ do Some r <- liftIO newIONonceGenerator
                    sym <- liftIO $ newSimpleBackend r
                    (p, _operands) <- forAllT (genParameterizedFormula sym OpSurf)
                    assert (all isValidParamType (SF.pfUses p))
    , testProperty "parameter type multiple" $
      property $ do Some r <- liftIO newIONonceGenerator
                    sym <- liftIO $ newSimpleBackend r
                    (p, _operands) <- forAllT (genParameterizedFormula sym OpPack)
                    assert (all isValidParamType (SF.pfUses p))
    , testProperty "operand type" $
      property $ do Some r <- liftIO newIONonceGenerator
                    sym <- liftIO $ newSimpleBackend r
                    (p, _operands) <- forAllT (genParameterizedFormula sym OpSurf)
                    assert $ isNatArgFoo ((SF.pfOperandVars p) SL.!! SL.index0)
    , testProperty "literal vars" $
      property $ do Some r <- liftIO newIONonceGenerator
                    sym <- liftIO $ newSimpleBackend r
                    _ <- forAllT (genParameterizedFormula sym OpSurf)
                    success -- TBD: something (manything?) to test literal vars here
      -- TBD: needs other tests
    , testProperty "defs keys in uses" $
      property $ do Some r <- liftIO newIONonceGenerator
                    sym <- liftIO $ newSimpleBackend r
                    (p, _operands) <- forAllT (genParameterizedFormula sym OpSurf)
                    assert (all (flip Set.member (SF.pfUses p)) (MapF.keys $ SF.pfDefs p))

    , testProperty "serialized formula round trip, simple backend, OpPack" $
      property $ do Some r <- liftIO newIONonceGenerator
                    sym <- liftIO $ newSimpleBackend r
                    let opcode = OpPack
                    (p, _operands) <- forAllT (genParameterizedFormula sym opcode)
                    debugPrint $ "parameterizedFormula: " <> show p
                    debugPrint $ "# literalVars: " <> show (MapF.size $ SF.pfLiteralVars p)
                    debugPrint $ "# defs: " <> show (MapF.size $ SF.pfDefs p)
                    let printedFormula = FO.printParameterizedFormula (HR.typeRepr opcode) p
                    debugPrint $ "printedFormula: " <> show printedFormula
                    let fenv = error "Formula Environment TBD"
                    lcfg <- liftIO $ Log.mkLogCfg "rndtrip"
                    reForm <- liftIO $
                              Log.withLogCfg lcfg $
                              FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula
                    debugPrint $ "re-Formulized: " <> show reForm
                    f <- evalEither reForm
                    compareParameterizedFormulasSimply sym 1 p f

    , testProperty "serialized formula round trip, simple backend, OpWave" $
      property $ do Some r <- liftIO newIONonceGenerator
                    sym <- liftIO $ newSimpleBackend r
                    let opcode = OpWave
                    (p, _operands) <- forAllT (genParameterizedFormula sym opcode)
                    debugPrint $ "parameterizedFormula: " <> show p
                    debugPrint $ "# literalVars: " <> show (MapF.size $ SF.pfLiteralVars p)
                    debugPrint $ "# defs: " <> show (MapF.size $ SF.pfDefs p)
                    let printedFormula = FO.printParameterizedFormula (HR.typeRepr opcode) p
                    debugPrint $ "printedFormula: " <> show printedFormula
                    let fenv = error "Formula Environment TBD"
                    lcfg <- liftIO $ Log.mkLogCfg "rndtrip"
                    reForm <- liftIO $
                              Log.withLogCfg lcfg $
                              FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula
                    debugPrint $ "re-Formulized: " <> show reForm
                    f <- evalEither reForm
                    compareParameterizedFormulasSimply sym 1 p f

    , testProperty "serialized formula round trip, simple backend, OpSolo" $
      property $ do Some r <- liftIO newIONonceGenerator
                    sym <- liftIO $ newSimpleBackend r
                    let opcode = OpSolo
                    (p, _operands) <- forAllT (genParameterizedFormula sym opcode)
                    debugPrint $ "parameterizedFormula: " <> show p
                    debugPrint $ "# literalVars: " <> show (MapF.size $ SF.pfLiteralVars p)
                    debugPrint $ "# defs: " <> show (MapF.size $ SF.pfDefs p)
                    let printedFormula = FO.printParameterizedFormula (HR.typeRepr opcode) p
                    debugPrint $ "printedFormula: " <> show printedFormula
                    let fenv = error "Formula Environment TBD"
                    lcfg <- liftIO $ Log.mkLogCfg "rndtrip"
                    reForm <- liftIO $
                              Log.withLogCfg lcfg $
                              FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula
                    debugPrint $ "re-Formulized: " <> show reForm
                    f <- evalEither reForm
                    compareParameterizedFormulasSimply sym 1 p f

    , testProperty "serialized formula round trip, online backend, OpWave" $
      property $
      E.handleAll (\e -> annotate (show e) >> failure) $ do
        Some r <- liftIO newIONonceGenerator
        CBO.withYicesOnlineBackend @(CBO.Flags CBO.FloatReal) r CBO.NoUnsatFeatures $ \sym -> do
          -- generate a formula
          let opcode = OpWave
          (p, operands) <- forAllT (genParameterizedFormula sym opcode)
          -- ensure that formula compares as equivalent to itself
          compareParameterizedFormulasSymbolically sym operands 1 p p
          -- now print the formula to a text string
          debugPrint $ "parameterizedFormula: " <> show p
          debugPrint $ "# literalVars: " <> show (MapF.size $ SF.pfLiteralVars p)
          debugPrint $ "# defs: " <> show (MapF.size $ SF.pfDefs p)
          let printedFormula = FO.printParameterizedFormula (HR.typeRepr opcode) p
          debugPrint $ "printedFormula: " <> show printedFormula
          -- convert the printed text string back into a formula
          let fenv = error "Formula Environment TBD"
          lcfg <- liftIO $ Log.mkLogCfg "rndtrip"
          reForm <- liftIO $
                    Log.withLogCfg lcfg $
                    FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula
          debugPrint $ "re-Formulized: " <> show reForm
          f <- evalEither reForm
          -- verify the recreated formula matches the original
          compareParameterizedFormulasSymbolically sym operands 1 p f

    , testProperty "serialized formula round trip, online backend, OpPack" $
      property $
      E.handleAll (\e -> annotate (show e) >> failure) $ do
        Some r <- liftIO newIONonceGenerator
        CBO.withYicesOnlineBackend @(CBO.Flags CBO.FloatReal) r CBO.NoUnsatFeatures $ \sym -> do
          -- generate a formula
          let opcode = OpPack
          (p, operands) <- forAllT (genParameterizedFormula sym opcode)
          -- ensure that formula compares as equivalent to itself
          compareParameterizedFormulasSymbolically sym operands 1 p p
          -- now print the formula to a text string
          debugPrint $ "parameterizedFormula: " <> show p
          debugPrint $ "# literalVars: " <> show (MapF.size $ SF.pfLiteralVars p)
          debugPrint $ "# defs: " <> show (MapF.size $ SF.pfDefs p)
          let printedFormula = FO.printParameterizedFormula (HR.typeRepr opcode) p
          debugPrint $ "printedFormula: " <> show printedFormula
          -- convert the printed text string back into a formula
          let fenv = error "Formula Environment TBD"
          lcfg <- liftIO $ Log.mkLogCfg "rndtrip"
          reForm <- liftIO $
                    Log.withLogCfg lcfg $
                    FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula
          debugPrint $ "re-Formulized: " <> show reForm
          f <- evalEither reForm
          -- verify the recreated formula matches the original
          compareParameterizedFormulasSymbolically sym operands 1 p f

    , testProperty "serialized formula round trip, online backend, OpSolo" $
      property $
      E.handleAll (\e -> annotate (show e) >> failure) $ do
        Some r <- liftIO newIONonceGenerator
        CBO.withYicesOnlineBackend @(CBO.Flags CBO.FloatReal) r CBO.NoUnsatFeatures $ \sym -> do
          -- generate a formula
          let opcode = OpSolo
          (p, operands) <- forAllT (genParameterizedFormula sym opcode)
          -- ensure that formula compares as equivalent to itself
          compareParameterizedFormulasSymbolically sym operands 1 p p
          -- now print the formula to a text string
          debugPrint $ "parameterizedFormula: " <> show p
          debugPrint $ "# literalVars: " <> show (MapF.size $ SF.pfLiteralVars p)
          debugPrint $ "# defs: " <> show (MapF.size $ SF.pfDefs p)
          let printedFormula = FO.printParameterizedFormula (HR.typeRepr opcode) p
          debugPrint $ "printedFormula: " <> show printedFormula
          -- convert the printed text string back into a formula
          let fenv = error "Formula Environment TBD"
          lcfg <- liftIO $ Log.mkLogCfg "rndtrip"
          reForm <- liftIO $
                    Log.withLogCfg lcfg $
                    FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula
          debugPrint $ "re-Formulized: " <> show reForm
          f <- evalEither reForm
          -- verify the recreated formula matches the original
          compareParameterizedFormulasSymbolically sym operands 1 p f

    , testProperty "serialized formula double round trip, OpWave" $
      property $
      E.handleAll (\e -> annotate (show e) >> failure) $ do
        Some r <- liftIO newIONonceGenerator
        CBO.withYicesOnlineBackend @(CBO.Flags CBO.FloatReal) r CBO.NoUnsatFeatures $ \sym -> do
          let opcode = OpWave
          lcfg <- liftIO $ Log.mkLogCfg "rndtrip"

          (p, operands) <- forAllT (genParameterizedFormula sym opcode)

          -- first round trip:
          let printedFormula = FO.printParameterizedFormula (HR.typeRepr opcode) p
          let fenv = error "Formula Environment TBD"
          reForm <- liftIO $
                    Log.withLogCfg lcfg $
                    FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula
          f <- evalEither reForm

          -- second round trip:
          let printedFormula' = FO.printParameterizedFormula (HR.typeRepr opcode) f
          reForm' <- liftIO $
                     Log.withLogCfg lcfg $
                     FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula'
          f' <- evalEither reForm'

          -- verification of results
          compareParameterizedFormulasSymbolically sym operands 1 p f
          compareParameterizedFormulasSymbolically sym operands 1 f f'
          -- KWQ: is variable renaming OK as long as the renaming is consistent and non-overlapping?
          compareParameterizedFormulasSymbolically sym operands 2 p f'

    , testProperty "serialized formula double round trip, OpPack" $
      property $
      E.handleAll (\e -> annotate (show e) >> failure) $ do
        Some r <- liftIO newIONonceGenerator
        CBO.withYicesOnlineBackend @(CBO.Flags CBO.FloatReal) r CBO.NoUnsatFeatures $ \sym -> do
          let opcode = OpPack
          lcfg <- liftIO $ Log.mkLogCfg "rndtrip"

          (p, operands) <- forAllT (genParameterizedFormula sym opcode)

          -- first round trip:
          let printedFormula = FO.printParameterizedFormula (HR.typeRepr opcode) p
          let fenv = error "Formula Environment TBD"
          reForm <- liftIO $
                    Log.withLogCfg lcfg $
                    FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula
          f <- evalEither reForm

          -- second round trip:
          let printedFormula' = FO.printParameterizedFormula (HR.typeRepr opcode) f
          reForm' <- liftIO $
                     Log.withLogCfg lcfg $
                     FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula'
          f' <- evalEither reForm'

          -- verification of results
          compareParameterizedFormulasSymbolically sym operands 1 p f
          compareParameterizedFormulasSymbolically sym operands 1 f f'
          compareParameterizedFormulasSymbolically sym operands 2 p f'

    , testProperty "serialized formula double round trip, OpSolo" $
      property $
      E.handleAll (\e -> annotate (show e) >> failure) $ do
        Some r <- liftIO newIONonceGenerator
        CBO.withYicesOnlineBackend @(CBO.Flags CBO.FloatReal) r CBO.NoUnsatFeatures $ \sym -> do
          let opcode = OpSolo
          lcfg <- liftIO $ Log.mkLogCfg "rndtrip"

          (p, operands) <- forAllT (genParameterizedFormula sym opcode)

          -- first round trip:
          let printedFormula = FO.printParameterizedFormula (HR.typeRepr opcode) p
          let fenv = error "Formula Environment TBD"
          reForm <- liftIO $
                    Log.withLogCfg lcfg $
                    FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula
          f <- evalEither reForm

          -- second round trip:
          let printedFormula' = FO.printParameterizedFormula (HR.typeRepr opcode) f
          reForm' <- liftIO $
                     Log.withLogCfg lcfg $
                     FI.readFormula sym fenv (HR.typeRepr opcode) printedFormula'
          f' <- evalEither reForm'

          -- verification of results
          compareParameterizedFormulasSymbolically sym operands 1 p f
          compareParameterizedFormulasSymbolically sym operands 1 f f'
          compareParameterizedFormulasSymbolically sym operands 2 p f'

    ]
  ]
  where
    isNatArgFoo :: BV.BoundVar sym TestGenArch "Foo" -> Bool
    isNatArgFoo _ = True
    isValidParamType (Some param) =
      case testEquality (SF.paramType param) BaseNatRepr of
        Just Refl -> True
        Nothing ->
          case testEquality (SF.paramType param) BaseIntegerRepr of
            Just Refl -> True
            Nothing ->
              let aBV32 = BaseBVRepr knownNat :: BaseTypeRepr (BaseBVType 32) in
              case testEquality (SF.paramType param) aBV32 of
                Just Refl -> True
                Nothing -> False
