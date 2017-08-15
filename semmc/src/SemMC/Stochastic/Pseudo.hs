{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE PolyKinds  #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module SemMC.Stochastic.Pseudo
  ( Pseudo
  , ArchitectureWithPseudo(..)
  , EmptyPseudo
  , pseudoAbsurd
  , SynthOpcode(..)
  , synthArbitraryOperands
  , SynthInstruction(..)
  , synthInsnToActual
  , actualInsnToSynth
  ) where

import           Data.Monoid ( (<>) )
import           Data.Parameterized.Classes
import           Data.Parameterized.HasRepr ( HasRepr(..) )
import           Data.Parameterized.ShapedList ( ShapedList, ShapeRepr )
import           Data.Parameterized.SymbolRepr ( SymbolRepr )
import           Data.Proxy ( Proxy(..) )
import           GHC.TypeLits ( Symbol )
import           Text.Printf ( printf )

import qualified Dismantle.Arbitrary as A
import qualified Dismantle.Instruction as D
import qualified Dismantle.Instruction.Random as D

import           SemMC.Architecture ( Architecture, Instruction, Operand, Opcode )

-- | The type of pseudo-ops for the given architecture.
--
-- If you don't want any pseudo-ops, then just use 'EmptyPseudo':
--
-- > type instance Pseudo <your arch> = EmptyPseudo
-- > instance ArchitectureWithPseudo <your arch> where
-- >   assemblePseudo _ = pseudoAbsurd
type family Pseudo arch :: (Symbol -> *) -> [Symbol] -> *

-- | An architecture with pseuo-ops.
class (Architecture arch,
       ShowF (Pseudo arch (Operand arch)),
       TestEquality (Pseudo arch (Operand arch)),
       OrdF (Pseudo arch (Operand arch)),
       HasRepr (Pseudo arch (Operand arch)) ShapeRepr,
       D.ArbitraryOperands (Pseudo arch) (Operand arch)) =>
      ArchitectureWithPseudo arch where
  -- | Turn a given pseudo-op with parameters into a series of actual,
  -- machine-level instructions.
  assemblePseudo :: proxy arch -> Pseudo arch o sh -> ShapedList o sh -> [Instruction arch]

----------------------------------------------------------------
-- * Helper type for arches with no pseudo ops
--
-- $emptyPseudo
--
-- See 'Pseudo' type family above for usage.

data EmptyPseudo o sh

deriving instance Show (EmptyPseudo o sh)

-- | Do proof-by-contradiction by eliminating an `EmptyPseudo`.
pseudoAbsurd :: EmptyPseudo o sh -> a
pseudoAbsurd = \case

instance D.ArbitraryOperands EmptyPseudo o where
  arbitraryOperands _gen = pseudoAbsurd

instance HasRepr (EmptyPseudo o) ShapeRepr where
  typeRepr = pseudoAbsurd

instance ShowF (EmptyPseudo o) where
  showF = pseudoAbsurd

instance TestEquality (EmptyPseudo o) where
  testEquality = pseudoAbsurd

instance OrdF (EmptyPseudo o) where
  compareF = pseudoAbsurd

----------------------------------------------------------------

-- | An opcode in the context of this learning process.
--
-- We need to represent it as such so that, when generating formulas, we can use
-- the much simpler direct formulas of the pseudo-ops, rather than the often
-- complicated formulas generated by the machine instructions equivalent to the
-- pseudo-op.
data SynthOpcode arch sh = RealOpcode (Opcode arch (Operand arch) sh)
                         -- ^ An actual, machine opcode
                         | PseudoOpcode (Pseudo arch (Operand arch) sh)
                         -- ^ A pseudo-op

instance (Show (Opcode arch (Operand arch) sh),
          Show (Pseudo arch (Operand arch) sh)) =>
         Show (SynthOpcode arch sh) where
  show (RealOpcode op) = printf "RealOpcode %s" (show op)
  show (PseudoOpcode pseudo) = printf "PseudoOpcode (%s)" (show pseudo)

instance forall arch . (ShowF (Opcode arch (Operand arch)),
                        ShowF (Pseudo arch (Operand arch))) =>
         ShowF (SynthOpcode arch) where
  withShow _ (_ :: q sh) x =
    withShow (Proxy @(Opcode arch (Operand arch))) (Proxy @sh) $
    withShow (Proxy @(Pseudo arch (Operand arch))) (Proxy @sh) $
    x

instance (TestEquality (Opcode arch (Operand arch)),
          TestEquality (Pseudo arch (Operand arch))) =>
         TestEquality (SynthOpcode arch) where
  testEquality (RealOpcode op1) (RealOpcode op2) =
    fmap (\Refl -> Refl) (testEquality op1 op2)
  testEquality (PseudoOpcode pseudo1) (PseudoOpcode pseudo2) =
    fmap (\Refl -> Refl) (testEquality pseudo1 pseudo2)
  testEquality _ _ = Nothing

instance (TestEquality (Opcode arch (Operand arch)),
          TestEquality (Pseudo arch (Operand arch))) =>
         Eq (SynthOpcode arch sh) where
  op1 == op2 = isJust (testEquality op1 op2)

mapOrderingF :: (a :~: b -> c :~: d) -> OrderingF a b -> OrderingF c d
mapOrderingF _ LTF = LTF
mapOrderingF f EQF =
  case f Refl of
    Refl -> EQF
mapOrderingF _ GTF = GTF

instance (OrdF (Opcode arch (Operand arch)),
          OrdF (Pseudo arch (Operand arch))) =>
         OrdF (SynthOpcode arch) where
  compareF (RealOpcode op1) (RealOpcode op2) =
    mapOrderingF (\Refl -> Refl) (compareF op1 op2)
  compareF (RealOpcode _) (PseudoOpcode _) = LTF
  compareF (PseudoOpcode _) (RealOpcode _) = GTF
  compareF (PseudoOpcode pseudo1) (PseudoOpcode pseudo2) =
    mapOrderingF (\Refl -> Refl) (compareF pseudo1 pseudo2)

instance (OrdF (Opcode arch (Operand arch)),
          OrdF (Pseudo arch (Operand arch))) =>
         Ord (SynthOpcode arch sh) where
  compare op1 op2 = toOrdering (compareF op1 op2)

instance (HasRepr ((Opcode arch) (Operand arch)) ShapeRepr,
          HasRepr ((Pseudo arch) (Operand arch)) ShapeRepr) =>
  HasRepr (SynthOpcode arch) (ShapedList SymbolRepr) where
  typeRepr (RealOpcode op) = typeRepr op
  typeRepr (PseudoOpcode op) = typeRepr op

-- | Generate random operands for the given 'SynthOpcode'.
synthArbitraryOperands :: (D.ArbitraryOperands (Opcode arch) (Operand arch),
                           D.ArbitraryOperands (Pseudo arch) (Operand arch))
                       => A.Gen
                       -> SynthOpcode arch sh
                       -> IO (ShapedList (Operand arch) sh)
synthArbitraryOperands gen (RealOpcode opcode) = D.arbitraryOperands gen opcode
synthArbitraryOperands gen (PseudoOpcode opcode) = D.arbitraryOperands gen opcode

-- | Like 'D.GenericInstruction', but can have either a real or a pseudo-opcode.
data SynthInstruction arch =
  forall sh . SynthInstruction (SynthOpcode arch sh) (ShapedList (Operand arch) sh)

instance (TestEquality (Opcode arch (Operand arch)),
          TestEquality (Pseudo arch (Operand arch)),
          TestEquality (Operand arch)) =>
         Eq (SynthInstruction arch) where
  SynthInstruction op1 list1 == SynthInstruction op2 list2 =
    isJust (testEquality op1 op2) && isJust (testEquality list1 list2)

instance (OrdF (Opcode arch (Operand arch)),
          OrdF (Pseudo arch (Operand arch)),
          OrdF (Operand arch)) =>
         Ord (SynthInstruction arch) where
  compare (SynthInstruction op1 list1) (SynthInstruction op2 list2) =
    toOrdering (compareF op1 op2) <> toOrdering (compareF list1 list2)

instance (ShowF (Operand arch), ShowF (Opcode arch (Operand arch)), ShowF (Pseudo arch (Operand arch))) => Show (SynthInstruction arch) where
  show (SynthInstruction op lst) =
    unwords [ "SynthInstruction"
            , showF op
            , show lst
            ]

-- | Convert a 'SynthInstruction' into a list of 'Instruction's, either by
-- pulling out the real opcode, or by assembling the pseudo-opcode into real
-- instructions.
synthInsnToActual :: forall arch . (ArchitectureWithPseudo arch) => SynthInstruction arch -> [Instruction arch]
synthInsnToActual (SynthInstruction opcode operands) =
  case opcode of
    RealOpcode opcode' -> [D.Instruction opcode' operands]
    PseudoOpcode opcode' -> assemblePseudo (Proxy @arch) opcode' operands

-- | Convert a machine-level 'Instruction' into a 'SynthInstruction'.
actualInsnToSynth :: Instruction arch -> SynthInstruction arch
actualInsnToSynth (D.Instruction opcode operands) = SynthInstruction (RealOpcode opcode) operands
