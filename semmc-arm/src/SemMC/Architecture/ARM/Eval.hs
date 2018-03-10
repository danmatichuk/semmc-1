-- | Evaluators for location functions in formula definitions (e.g., memri_reg)

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module SemMC.Architecture.ARM.Eval
    ( createSymbolicEntries
    , interpIsR15
    , interpAm2offsetimmImmExtractor
    , interpAm2offsetimmAddExtractor
    , interpBlxTarget_S
    , interpBlxTarget_imm10H
    , interpBlxTarget_imm10L
    , interpBlxTarget_J1
    , interpBlxTarget_J2
    , interpImm12Reg
    , interpImm12RegExtractor
    , interpImm12OffsetExtractor
    , interpImm12AddFlgExtractor
    , interpImm01020s4ImmExtractor
    , interpLdstsoregAddExtractor
    , interpLdstsoregImmExtractor
    , interpLdstsoregTypeExtractor
    , interpLdstsoregBaseRegExtractor
    , interpLdstsoregBaseReg
    , interpLdstsoregOffRegExtractor
    , interpLdstsoregOffReg
    , interpModimmImmExtractor
    , interpModimmRotExtractor
    , interpSoregimmTypeExtractor
    , interpSoregimmImmExtractor
    , interpSoregimmRegExtractor
    , interpSoregimmReg
    , interpSoregregTypeExtractor
    , interpSoregregReg1Extractor
    , interpSoregregReg2Extractor
    , interpSoregregReg1
    , interpSoregregReg2
    , interpT2soimmImmExtractor
    , interpTReglistExtractor
    )
    where

import           Data.Int ( Int16, Int8 )
import qualified Data.Parameterized.List as PL
import qualified Data.Word.Indexed as W
import qualified Dismantle.ARM as ARMDis
import qualified Dismantle.ARM.Operands as ARMOperands
import qualified Dismantle.Thumb as ThumbDis
import qualified Dismantle.Thumb.Operands as ThumbOperands
import           Lang.Crucible.BaseTypes
import           SemMC.Architecture.ARM.Combined
import           SemMC.Architecture.ARM.Location
import qualified SemMC.Architecture.Location as L
import qualified SemMC.Formula as F


-- | Uninterpreted function names are mangled in SimpleBuilder, so we need to
-- create extra entries to match their mangled names.
--
-- In particular, periods in names are converted to underscores.
--
-- This function creates copies of entries with periods in their names with the
-- escaped version as it appears in a SimpleBuilder symbolic function.  For
-- example, if there is an entry with the name @arm.foo@, this function retains
-- that entry in the input list and adds an additional entry under @arm_foo@.
createSymbolicEntries :: [(String, a)] -> [(String, a)]
createSymbolicEntries = foldr duplicateIfDotted []
  where
    duplicateIfDotted elt@(s, e) acc =
      case '.' `elem` s of
        False -> acc
        True ->
          let newElt = (map (\c -> if c == '.' then '_' else c) s, e)
          in newElt : elt : acc


------------------------------------------------------------------------
-- | Extract values from the ARM Am2offset_imm operand

interpAm2offsetimmImmExtractor :: ARMOperands.Am2OffsetImm -> Int16
interpAm2offsetimmImmExtractor = fromInteger . toInteger . ARMOperands.am2OffsetImmImmediate

interpAm2offsetimmAddExtractor :: ARMOperands.Am2OffsetImm -> Bool
interpAm2offsetimmAddExtractor = (== 1) . ARMOperands.am2OffsetImmAdd


------------------------------------------------------------------------
-- | Extract values from the ARM Addrmode_imm12 operand

-- | Extract the register value from an addrmode_imm12[_pre] via
-- the a32.imm12_reg user function.
interpImm12Reg :: forall sh s arm tp
                   . (L.IsLocation (Location arm), L.Location arm ~ Location arm)
                   => PL.List ARMOperand sh
                 -> F.WrappedOperand arm sh s
                 -> BaseTypeRepr tp
                 -> L.Location arm tp
interpImm12Reg operands (F.WrappedOperand _orep ix) rep =
  case operands PL.!! ix of
    A32Operand (ARMDis.Addrmode_imm12_pre oprnd) ->
      let loc :: Location arm (BaseBVType (ArchRegWidth arm))
          loc = LocGPR $ ARMOperands.unGPR $ ARMOperands.addrModeImm12Register oprnd
      in case () of
        _ | Just Refl <- testEquality (L.locationType loc) rep -> loc
          | otherwise -> error ("Invalid return type for location function 'imm12_reg' at index " ++ show ix)
    _ -> error ("Invalid operand type at index " ++ show ix)

-- n.b. there is no Nothing, but the call in macaw.SemMC.TH expects a Maybe result.
interpImm12RegExtractor :: ARMOperands.AddrModeImm12 -> Maybe ARMOperands.GPR
interpImm12RegExtractor = Just . ARMOperands.addrModeImm12Register

interpImm12OffsetExtractor :: ARMOperands.AddrModeImm12 -> Int16
interpImm12OffsetExtractor = fromInteger . toInteger . ARMOperands.addrModeImm12Immediate

interpImm12AddFlgExtractor :: ARMOperands.AddrModeImm12 -> Bool
interpImm12AddFlgExtractor = (== 1) . ARMOperands.addrModeImm12Add


------------------------------------------------------------------------
-- | Extract values from the Thumb Imm0_1020S4 operand

interpImm01020s4ImmExtractor :: ThumbOperands.TImm01020S4 -> Int8
interpImm01020s4ImmExtractor = fromInteger . toInteger . ThumbOperands.tImm01020S4ToBits


------------------------------------------------------------------------
-- | Extract values from the ARM LdstSoReg operand

interpLdstsoregAddExtractor :: ARMOperands.LdstSoReg -> Bool
interpLdstsoregAddExtractor = (== 1) . ARMOperands.ldstSoRegAdd

interpLdstsoregImmExtractor :: ARMOperands.LdstSoReg -> W.W 5
interpLdstsoregImmExtractor = fromInteger . toInteger . ARMOperands.ldstSoRegImmediate

interpLdstsoregTypeExtractor :: ARMOperands.LdstSoReg -> W.W 2
interpLdstsoregTypeExtractor = fromInteger . toInteger . ARMOperands.ldstSoRegShiftType

-- n.b. there is no Nothing, but the call in macaw.SemMC.TH expects a Maybe result.
interpLdstsoregBaseRegExtractor :: ARMOperands.LdstSoReg -> Maybe ARMOperands.GPR
interpLdstsoregBaseRegExtractor = Just . ARMOperands.ldstSoRegBaseRegister

-- n.b. there is no Nothing, but the call in macaw.SemMC.TH expects a Maybe result.
interpLdstsoregOffRegExtractor :: ARMOperands.LdstSoReg -> Maybe ARMOperands.GPR
interpLdstsoregOffRegExtractor = Just . ARMOperands.ldstSoRegOffsetRegister


interpLdstsoregBaseReg :: forall sh s arm tp
                          . (L.IsLocation (Location arm), L.Location arm ~ Location arm) =>
                          PL.List ARMOperand sh
                       -> F.WrappedOperand arm sh s
                       -> BaseTypeRepr tp
                       -> L.Location arm tp
interpLdstsoregBaseReg operands (F.WrappedOperand _orep ix) rep =
  case operands PL.!! ix of
    A32Operand (ARMDis.Ldst_so_reg oprnd) ->
      let loc :: Location arm (BaseBVType (ArchRegWidth arm))
          loc = LocGPR $ ARMOperands.unGPR $ ARMOperands.ldstSoRegBaseRegister oprnd
      in case () of
        _ | Just Refl <- testEquality (L.locationType loc) rep -> loc
          | otherwise -> error ("Invalid return type for location function 'ldst_so_reg' base reg at index " ++ show ix)
    _ -> error ("Invalid operand type at index " ++ show ix)

interpLdstsoregOffReg :: forall sh s arm tp
                         . (L.IsLocation (Location arm), L.Location arm ~ Location arm) =>
                         PL.List ARMOperand sh
                      -> F.WrappedOperand arm sh s
                      -> BaseTypeRepr tp
                      -> L.Location arm tp
interpLdstsoregOffReg operands (F.WrappedOperand _orep ix) rep =
  case operands PL.!! ix of
    A32Operand (ARMDis.Ldst_so_reg oprnd) ->
      let loc :: Location arm (BaseBVType (ArchRegWidth arm))
          loc = LocGPR $ ARMOperands.unGPR $ ARMOperands.ldstSoRegOffsetRegister oprnd
      in case () of
        _ | Just Refl <- testEquality (L.locationType loc) rep -> loc
          | otherwise -> error ("Invalid return type for location function 'ldst_so_reg' offset reg at index " ++ show ix)
    _ -> error ("Invalid operand type at index " ++ show ix)

------------------------------------------------------------------------
-- | Extract values from the ARM Mod_imm operand

interpModimmImmExtractor :: ARMOperands.ModImm -> Int8
interpModimmImmExtractor = fromInteger . toInteger . ARMOperands.modImmOrigImmediate

interpModimmRotExtractor :: ARMOperands.ModImm -> W.W 4
interpModimmRotExtractor = fromInteger . toInteger . ARMOperands.modImmOrigRotate


------------------------------------------------------------------------
-- | Extract values from the Thumb ThumbBlxTarget operand

interpBlxTarget_S :: ThumbOperands.ThumbBlxTarget -> W.W 1
interpBlxTarget_S = fromInteger . toInteger . ThumbOperands.thumbBlxTargetS

interpBlxTarget_J1 :: ThumbOperands.ThumbBlxTarget -> W.W 1
interpBlxTarget_J1 = fromInteger . toInteger . ThumbOperands.thumbBlxTargetJ1

interpBlxTarget_J2 :: ThumbOperands.ThumbBlxTarget -> W.W 1
interpBlxTarget_J2 = fromInteger . toInteger . ThumbOperands.thumbBlxTargetJ2

interpBlxTarget_imm10H :: ThumbOperands.ThumbBlxTarget -> W.W 10
interpBlxTarget_imm10H = fromInteger . toInteger . ThumbOperands.thumbBlxTargetImm10H

interpBlxTarget_imm10L :: ThumbOperands.ThumbBlxTarget -> W.W 10
interpBlxTarget_imm10L = fromInteger . toInteger . ThumbOperands.thumbBlxTargetImm10L


------------------------------------------------------------------------
-- | Extract values from the ARM SoRegImm operand

interpSoregimmTypeExtractor :: ARMOperands.SoRegImm -> W.W 2
interpSoregimmTypeExtractor = fromInteger . toInteger . ARMOperands.soRegImmShiftType

interpSoregimmImmExtractor :: ARMOperands.SoRegImm -> W.W 5
interpSoregimmImmExtractor = fromInteger . toInteger . ARMOperands.soRegImmImmediate

-- n.b. there is no Nothing, but the call in macaw.SemMC.TH expects a Maybe result.
interpSoregimmRegExtractor :: ARMOperands.SoRegImm -> Maybe ARMOperands.GPR
interpSoregimmRegExtractor = Just . ARMOperands.soRegImmReg


-- | Extract the register value from a SoRegReg via the
-- a32.soregimm_reg user function.
interpSoregimmReg :: forall sh s arm tp
                     . (L.IsLocation (Location arm), L.Location arm ~ Location arm) =>
                     PL.List ARMOperand sh
                  -> F.WrappedOperand arm sh s
                  -> BaseTypeRepr tp
                  -> L.Location arm tp
interpSoregimmReg operands (F.WrappedOperand _orep ix) rep =
  case operands PL.!! ix of
    A32Operand (ARMDis.So_reg_imm oprnd) ->
      let loc :: Location arm (BaseBVType (ArchRegWidth arm))
          loc = LocGPR $ ARMOperands.unGPR $ ARMOperands.soRegImmReg oprnd
      in case () of
        _ | Just Refl <- testEquality (L.locationType loc) rep -> loc
          | otherwise -> error ("Invalid return type for location function 'soregimm_reg' at index " ++ show ix)
    _ -> error ("Invalid operand type at index " ++ show ix)


------------------------------------------------------------------------
-- | Extract values from the ARM SoRegReg operand

-- n.b. there is no Nothing, but the call in macaw.SemMC.TH expects a Maybe result.
interpSoregregReg1Extractor :: ARMOperands.SoRegReg -> Maybe ARMOperands.GPR
interpSoregregReg1Extractor = Just . ARMOperands.soRegRegReg1

-- n.b. there is no Nothing, but the call in macaw.SemMC.TH expects a Maybe result.
interpSoregregReg2Extractor :: ARMOperands.SoRegReg -> Maybe ARMOperands.GPR
interpSoregregReg2Extractor = Just . ARMOperands.soRegRegReg2

interpSoregregTypeExtractor :: ARMOperands.SoRegReg -> W.W 2
interpSoregregTypeExtractor = fromInteger . toInteger . ARMOperands.soRegRegShiftType

-- | Extract the register value from a SoRegReg via the
-- a32.soregreg_reg user function.
interpSoregregReg1 :: forall sh s arm tp
                      . (L.IsLocation (Location arm), L.Location arm ~ Location arm) =>
                      PL.List ARMOperand sh
                   -> F.WrappedOperand arm sh s
                   -> BaseTypeRepr tp
                   -> L.Location arm tp
interpSoregregReg1 operands (F.WrappedOperand _orep ix) rep =
  case operands PL.!! ix of
    A32Operand (ARMDis.So_reg_reg oprnd) ->
      let loc :: Location arm (BaseBVType (ArchRegWidth arm))
          loc = LocGPR $ ARMOperands.unGPR $ ARMOperands.soRegRegReg1 oprnd
      in case () of
        _ | Just Refl <- testEquality (L.locationType loc) rep -> loc
          | otherwise -> error ("Invalid return type for location function 'soregreg_reg' 1 at index " ++ show ix)
    _ -> error ("Invalid operand type 1 at index " ++ show ix)


-- | Extract the register value from a SoRegReg via the
-- a32.soregreg_reg user function.
interpSoregregReg2 :: forall sh s arm tp
                      . (L.IsLocation (Location arm), L.Location arm ~ Location arm) =>
                      PL.List ARMOperand sh
                   -> F.WrappedOperand arm sh s
                   -> BaseTypeRepr tp
                   -> L.Location arm tp
interpSoregregReg2 operands (F.WrappedOperand _orep ix) rep =
  case operands PL.!! ix of
    A32Operand (ARMDis.So_reg_reg oprnd) ->
      let loc :: Location arm (BaseBVType (ArchRegWidth arm))
          loc = LocGPR $ ARMOperands.unGPR $ ARMOperands.soRegRegReg2 oprnd
      in case () of
        _ | Just Refl <- testEquality (L.locationType loc) rep -> loc
          | otherwise -> error ("Invalid return type for location function 'soregreg_reg' 2 at index " ++ show ix)
    _ -> error ("Invalid operand type 2 at index " ++ show ix)


------------------------------------------------------------------------
-- | Extract values from the Thumb SoRegImm operand

interpT2soimmImmExtractor :: ThumbOperands.T2SoImm -> W.W 12
interpT2soimmImmExtractor = fromInteger . toInteger . ThumbOperands.t2SoImmToBits


------------------------------------------------------------------------
-- | Extract values from the Thumb Reglist operand

interpTReglistExtractor :: ThumbOperands.Reglist -> Int16
interpTReglistExtractor = fromInteger . toInteger . ThumbOperands.regListToBits


------------------------------------------------------------------------

-- | Determination of whether this register reference is for R15
-- (which is often, but not always, the PC).

class InterpIsR15 a where
  interpIsR15 :: a -> Bool

instance InterpIsR15 ARMOperands.GPR where
    interpIsR15 gprReg = ARMOperands.unGPR gprReg == 15

instance InterpIsR15 (Maybe ARMOperands.GPR) where
  interpIsR15 mr =
    case mr of
      Nothing -> True
      Just r -> interpIsR15 r

instance InterpIsR15 ThumbOperands.GPR where
    interpIsR15 gprReg = ThumbOperands.unGPR gprReg == 15

instance InterpIsR15 (Maybe ThumbOperands.GPR) where
  interpIsR15 mr =
    case mr of
      Nothing -> True
      Just r -> interpIsR15 r


instance InterpIsR15 ThumbOperands.LowGPR where
    interpIsR15 gprReg = ThumbOperands.unLowGPR gprReg == 15

instance InterpIsR15 (Maybe ThumbOperands.LowGPR) where
  interpIsR15 mr =
    case mr of
      Nothing -> True
      Just r -> interpIsR15 r
