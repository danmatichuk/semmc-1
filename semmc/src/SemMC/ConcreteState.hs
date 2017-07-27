{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}

module SemMC.ConcreteState
  ( Value(..)
  , View(..)
  , trivialView
  , Slice(..)
  , peekSlice
  , pokeSlice
  , ConcreteState
  , peekMS
  , pokeMS
  , Diff
  , OutMask(..)
  , OutMasks
  , ConcreteArchitecture(..)
  ) where

import           Data.Bits ( Bits, complement, (.&.), (.|.), shiftL, shiftR )
import qualified Data.ByteString as B
import           Data.Maybe ( fromJust )
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.NatRepr ( NatRepr, widthVal, knownNat )
import           Data.Parameterized.Some ( Some )
import qualified Data.Word.Indexed as W
import           GHC.TypeLits ( KnownNat, Nat, type (+), type (<=) )

import qualified Dismantle.Arbitrary as A

import           Lang.Crucible.BaseTypes ( BaseBVType )

import           SemMC.Architecture ( Architecture, ArchState, Location, Operand )

----------------------------------------------------------------
-- Locations, values, and views

-- | Type of concrete values.
data Value tp where
  ValueBV :: W.W n -> Value (BaseBVType n)

deriving instance (KnownNat n) => Show (Value (BaseBVType n))
deriving instance Eq (Value tp)
deriving instance Ord (Value tp)

instance (KnownNat n) => A.Arbitrary (Value (BaseBVType n)) where
  arbitrary gen = ValueBV <$> A.arbitrary gen

-- | A view into a location. Could be the whole location.
--
-- E.g.
--
-- > pattern F12 = View (Slice 0 64 :: Slice 64) VSX12 :: View PPC 64
--
-- Note that (non-immediate) operands are like 'View's, not
-- 'Location's.
--
-- The @m@ parameter is the size (number of bits) of the view.
--
-- The @n@ parameter is the size of the underlying location.
--
-- The @s@ parameter is the start bit of the slice.
data View arch (m :: Nat) where
  View :: Slice m n -> Location arch (BaseBVType n) -> View arch m

-- | A slice of a bit vector.
--
-- Could even go crazy, enforcing at the type level that the slice
-- makes sense:
--
-- > data Slice (m :: Nat) (n :: Nat) where
-- >   Slice :: (a <= b, a+m ~ b, b <= n) => NatRepr a -> NatRepr b :: Slice m n
--
-- but that might be overkill.
--
-- A slice is @m@ bits long in a @n@ bit base location
--
-- @a@ is the start bit and @b@ is the end bit
data Slice (m :: Nat) (n :: Nat) where
  Slice :: ( a+1 <= b   -- Slices are non-empty
           , (a+m) ~ b  -- The last bit (b) and length of slice (m) are consistent
           , b <= n)    -- The last bit (b) doesn't run off the end of the location (n)
        => NatRepr a -> NatRepr b -> Slice m n

-- data Slice (l :: Nat) (h :: Nat) where
--   Slice :: (KnownNat l, KnownNat h, l < h) => Slice l h

-- | Produce a view of an entire location
trivialView :: forall arch n . (KnownNat n, 1 <= n) => Location arch (BaseBVType n) -> View arch n
trivialView loc = View s loc
  where
    s :: Slice n n
    s = Slice (knownNat :: NatRepr 0) (knownNat :: NatRepr n)

onesMask :: (Integral a, Bits b, Num b) => a -> b
onesMask sz = shiftL 1 (fromIntegral sz) - 1

-- | Read sliced bits.
peekSlice :: Slice m n -> Value (BaseBVType n) -> Value (BaseBVType m)
peekSlice (Slice (widthVal -> a) (widthVal -> b)) (ValueBV (W.W (toInteger -> val))) =
  (ValueBV . W.W . fromInteger) ((val .&. onesMask b) `shiftR` a)

-- | Write sliced bits.
pokeSlice :: Slice m n -> Value (BaseBVType n) -> Value (BaseBVType m) -> Value (BaseBVType n)
pokeSlice (Slice (widthVal -> a) (widthVal -> b)) (ValueBV (W.W (toInteger -> x))) (ValueBV (W.W (toInteger -> y))) =
  let shiftedY = y `shiftL` a
      clearLower nLower val = (val `shiftR` nLower) `shiftL` nLower
      xMask = complement (clearLower a (onesMask b))
  in (ValueBV . W.W . fromInteger) (shiftedY .|. (x .&. xMask))

----------------------------------------------------------------
-- Machine states

-- | Concrete machine state.
--
-- Current we have symbolic machine state in 'ConcreteState'.
type ConcreteState arch = ArchState arch Value

-- | Read machine states.
peekMS :: (OrdF (Location arch)) => ConcreteState arch -> View arch n -> Value (BaseBVType n)
peekMS = flip peekMS'
  where peekMS' (View sl loc) = peekSlice sl . fromJust . MapF.lookup loc

-- | Write machine states.
--
-- This function is "dumb", in that it's not concerned with
-- e.g. zeroing out the upper bits of VSX12 when writing F12.
pokeMS :: (OrdF (Location arch)) => ConcreteState arch -> View arch n -> Value (BaseBVType n) -> ConcreteState arch
pokeMS m (View sl loc) newPart = MapF.insert loc new m
  where orig = fromJust (MapF.lookup loc m)
        new = pokeSlice sl orig newPart


----------------------------------------------------------------
-- Comparing machine states in stratified synthesis

-- | Compute bit-error difference in two values.
--
-- Different depending on whether values are treated as integers
-- (regular equality) or floating point (equivalence relation that
-- equates various NaN representations).
type Diff n = Value (BaseBVType n) -> Value (BaseBVType n) -> Int

-- | Some state that is live out of an instruction.
data OutMask arch n = OutMask (View arch n) (Diff n)

-- | All state that is live out of an instruction.
--
-- Need to learn one of these for each instruction.
type OutMasks arch = [Some (OutMask arch)]

-- | An architecture with certain operations needed for concrete work.
class (Architecture arch) => ConcreteArchitecture arch where
  -- | Convert an operand to the corresponding view, if any.
  --
  -- Useful for perturbing a machine state when computing the IO
  -- relation for an instruction?
  operandToView :: proxy arch -> Operand arch sh -> Maybe (Some (View arch))

  -- | Return the other places where we should look for our target
  -- values in the candidate's out state.
  congruentViews :: proxy arch -> View arch n -> [View arch n]

  -- | Construct a complete state with all locations set to zero
  --
  -- This is a useful starting point for constructing a desired state to ensure
  -- that all locations are filled in.
  zeroState :: proxy arch -> ConcreteState arch

  -- | Generate a completely random state
  --
  -- The random state has all locations filled in
  randomState :: proxy arch -> A.Gen -> IO (ConcreteState arch)

  -- | Convert a 'ConcreteState' into a 'B.ByteString'
  serialize :: proxy arch -> ConcreteState arch -> B.ByteString

  -- | Try to convert a 'B.ByteString' into a 'ConcreteState'
  deserialize :: proxy arch -> B.ByteString -> Maybe (ConcreteState arch)
