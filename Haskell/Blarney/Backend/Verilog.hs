{-# LANGUAGE NoRebindableSyntax #-}

{-|
Module      : Blarney.Backend.Verilog
Description : Verilog generation
Copyright   : (c) Matthew Naylor, 2019
              (c) Alexandre Joannou, 2019-2021
License     : MIT
Maintainer  : mattfn@gmail.com
Stability   : experimental

Convert Blarney Netlist to Verilog modules.
-}

module Blarney.Backend.Verilog (
  genVerilogModule -- Generate Verilog module
, genVerilogTop    -- Generate Verilog top-level module
) where

-- Standard imports
import Prelude hiding ( (<>) )
import qualified Data.Set as Set
import Data.Bits ( (.&.), shiftR )
import Data.List
import System.IO
import Data.Maybe
import System.Process
import Text.PrettyPrint
import Numeric (showHex)
import Data.Array.IArray

-- Blarney imports
import Blarney.Core.Utils
import Blarney.Netlist

-- Toplevel API
--------------------------------------------------------------------------------

-- | Convert given Blarney Netlist to a Verilog module
genVerilogModule :: Netlist -- ^ Blarney netlist
                 -> String  -- ^ Module name
                 -> String  -- ^ Output directory
                 -> IO ()
genVerilogModule nl mod dir =
  do system ("mkdir -p " ++ dir)
     writeVerilog fileName mod nl
  where fileName = dir ++ "/" ++ mod ++ ".v"

-- | Convert given Blarney Netlist to a top-level Verilog module, and
-- automatically generate a sample verilator wrapper and makefile too.
-- This is useful for simple examples and projects.  Most projects will
-- probably require a more customised verilator wrapper;
-- in that case, just use 'genVerilogModule', even for the top-level
-- module.
genVerilogTop :: Netlist -- ^ Blarney module
              -> String  -- ^ Top-level module name
              -> String  -- ^ Output directory
              -> IO ()
genVerilogTop nl mod dir =
  do genVerilogModule nl mod dir
     writeFile (dir ++ "/" ++ mod ++ ".cpp") simCode
     writeFile (dir ++ "/" ++ mod ++ ".mk") makefileIncCode
     writeFile (dir ++ "/Makefile") makefileCode
  where simCode = unlines [
            "// Generated by Blarney"
          , "#include <verilated.h>"
          , "#include \"V" ++ mod ++ ".h\""
          , "V" ++ mod ++ " *top;"
          , "vluint64_t main_time = 0;"
          , "// Called by $time in Verilog"
          , "double sc_time_stamp () {"
          , "  return main_time;"
          , "}"
          , "int main(int argc, char** argv) {"
          , "  Verilated::commandArgs(argc, argv);"
          , "  top = new V" ++ mod ++ ";"
          , "  while (!Verilated::gotFinish()) {"
          , "    top->clock = 0; top->eval();"
          , "    top->clock = 1; top->eval();"
          , "    main_time++;"
          , "  }"
          , "  top->final(); delete top; return 0;"
          , "}" ]
        makefileIncCode = unlines [
            "all: " ++ mod
          , mod ++ ": *.v *.cpp"
          , "\tverilator -cc " ++ mod ++ ".v " ++ "-exe "
                               ++ mod ++ ".cpp " ++ "-o " ++ mod
                               ++ " -Wno-UNSIGNED"
                               ++ " -y $(BLARNEY_ROOT)/Verilog"
                               ++ " --x-assign unique"
                               ++ " --x-initial unique"
          , "\tmake -C obj_dir -j -f V" ++ mod ++ ".mk " ++ mod
          , "\tcp obj_dir/" ++ mod ++ " ."
          , "\trm -rf obj_dir"
          , ".PHONY: clean clean-" ++ mod
          , "clean: clean-" ++ mod
          , "clean-" ++ mod ++ ":"
          , "\trm -f " ++ mod ]
        makefileCode = "include *.mk"

writeVerilog :: String -> String -> Netlist -> IO ()
writeVerilog fileName modName netlist = do
  h <- openFile fileName WriteMode
  hPutStr h (render $ showVerilogModule modName netlist)
  hClose h

-- Internal helpers
--------------------------------------------------------------------------------

-- NetVerilog helper type
data NetVerilog = NetVerilog { decl :: Maybe Doc -- declaration
                             , inst :: Maybe Doc -- instanciation
                             , alws :: Maybe Doc -- always block
                             , rst  :: Maybe Doc -- reset logic
                             }
-- pretty helpers
--------------------------------------------------------------------------------
dot = char '.'
spaces n = hcat $ replicate n space
hexInt n = text (showHex n "")
argStyle as = sep $ punctuate comma as

showVerilogModule :: String -> Netlist -> Doc
showVerilogModule modName netlst =
      hang (hang (text "module" <+> text modName) 2 (parens (showIOs)) <> semi)
        2 moduleBody
  $+$ text "endmodule"
  where moduleBody =
              showComment "Declarations" $+$ showCommentLine
          $+$ sep (catMaybes $ map decl netVs)
          $+$ showComment "Instances" $+$ showCommentLine
          $+$ sep (catMaybes $ map inst netVs)
          $+$ showComment "Always block" $+$ showCommentLine
          $+$ hang (text "always"
                    <+> char '@' <> parens (text "posedge clock")
                    <+> text "begin") 2 alwaysBody
          $+$ text "end"
        alwaysBody =
              hang (text "if (reset) begin") 2 (sep (catMaybes $ map rst netVs))
          $+$ hang (text "end else begin") 2 (sep (catMaybes $ map alws netVs))
          $+$ text "end"
        nets = elems netlst
        netVs = map (genNetVerilog netlst) nets
        netPrims = map netPrim nets
        ins = [Input w s | (w, s) <- nub [(w, s) | Input w s <- netPrims]]
        outs = [Output w s | Output w s <- netPrims]
        showIOs = argStyle $ text "input wire clock"
                           : text "input wire reset"
                           : map showIO (ins ++ outs)
        showIO (Input w s) =     text "input wire"
                             <+> brackets (int (w-1) <> text ":0")
                             <+> text s
        showIO (Output w s) = text "output wire"
                              <+> brackets (int (w-1) <> text ":0")
                              <+> text s
        showIO _ = text ""
        showComment cmt = text "//" <+> text cmt
        --showCommentLine = remainCols (\r -> p "//" <> p (replicate (r-2) '/'))
        showCommentLine = text (replicate 78 '/')

-- generate NetVerilog
--------------------------------------------------------------------------------
genNetVerilog :: Netlist -> Net -> NetVerilog
genNetVerilog netlist net = case netPrim net of
  Add w                   -> primNV { decl = Just $ declWire w wId }
  Sub w                   -> primNV { decl = Just $ declWire w wId }
  Mul w _ isFull
    | isFull              -> primNV { decl = Just $ declWire (2*w) wId }
    | otherwise           -> primNV { decl = Just $ declWire w wId }
  Div w                   -> primNV { decl = Just $ declWire w wId }
  Mod w                   -> primNV { decl = Just $ declWire w wId }
  Not w                   -> primNV { decl = Just $ declWire w wId }
  And w                   -> primNV { decl = Just $ declWire w wId }
  Or w                    -> primNV { decl = Just $ declWire w wId }
  Xor w                   -> primNV { decl = Just $ declWire w wId }
  ShiftLeft _ w           -> primNV { decl = Just $ declWire w wId }
  ShiftRight _ w          -> primNV { decl = Just $ declWire w wId }
  ArithShiftRight _ w     -> primNV { decl = Just $ declWire w wId }
  Equal w                 -> primNV { decl = Just $ declWire 1 wId }
  NotEqual w              -> primNV { decl = Just $ declWire 1 wId }
  LessThan w              -> primNV { decl = Just $ declWire 1 wId }
  LessThanEq w            -> primNV { decl = Just $ declWire 1 wId }
  ReplicateBit w          -> primNV { decl = Just $ declWire w wId }
  ZeroExtend wi wo        -> primNV { decl = Just $ declWire wo wId }
  SignExtend wi wo        -> primNV { decl = Just $ declWire wo wId }
  SelectBits w hi lo      -> primNV { decl = Just $ declWire (1+hi-lo) wId }
  Concat aw bw            -> primNV { decl = Just $ declWire (aw+bw) wId }
  Identity w              -> primNV { decl = Just $ declWire w wId }
  MergeWrites s n w       -> primNV { decl = Just $ declWire w wId }
  Mux _ wsel w            -> dfltNV { decl = Just $ declMux wsel w net
                                    , inst = Just $ instMux net }
  Const w i               -> dfltNV { decl = Just $ declWireInit w wId i }
  DontCare w              -> dfltNV { decl = Just $ declWireDontCare w wId }
  Register i w            -> dfltNV { decl = Just $ declRegInit w wId i
                                    , alws = Just $ alwsRegister net
                                    , rst  = Just $ resetRegister w wId i }
  RegisterEn i w          -> dfltNV { decl = Just $ declRegInit w wId i
                                    , alws = Just $ alwsRegisterEn net
                                    , rst  = Just $ resetRegister w wId i }
  BRAM BRAMSinglePort i aw dw be ->
    dfltNV { decl = Just $ declRAM i 1 aw dw net
           , inst = Just $ instRAM net i aw dw be }
  BRAM BRAMDualPort i aw dw be ->
    dfltNV { decl = Just $ declRAM i 1 aw dw net
           , inst = Just $ instRAM net i aw dw be }
  BRAM BRAMTrueDualPort i aw dw be ->
    dfltNV { decl = Just $ declRAM i 2 aw dw net
           , inst = Just $ instTrueDualRAM net i aw dw be }
  Display args            -> dfltNV { alws = Just $ alwsDisplay args net }
  Finish                  -> dfltNV { alws = Just $ alwsFinish net }
  TestPlusArgs s          -> dfltNV { decl = Just $ declWire 1 wId
                                    , inst = Just $ instTestPlusArgs wId s }
  Input w s               -> dfltNV { decl = Just $ declWire w wId
                                    , inst = Just $ instInput net s }
  Output w s              -> dfltNV { inst = Just $ instOutput net s }
  Assert msg              -> dfltNV { alws = Just $ alwsAssert net msg }
  RegFileMake rfinfo
    -> dfltNV { decl = Just $ declRegFile rfinfo }
  RegFileRead RegFileInfo{ regFileId = vId, regFileDataWidth = w }
    -> dfltNV { decl = Just $ declWire w wId
              , inst = Just $ instRegFileRead vId net }
  RegFileWrite RegFileInfo{ regFileId = vId }
    -> dfltNV { alws = Just $ alwsRegFileWrite vId net }
  Custom p is os ps clked resetable nlgen
    -> dfltNV { decl = Just $ sep [ declWire w (netInstId net, Just nm)
                                  | (nm, w) <- os ]
              , inst = Just $ instCustom net p is os ps clked resetable }
  --_ -> dfltNV
  where
  wId = (netInstId net, Nothing)
  dfltNV = NetVerilog { decl = Nothing
                      , inst = Nothing
                      , alws = Nothing
                      , rst  = Nothing }
  primNV = dfltNV { inst = Just $ instPrim net }
  -- general helpers
  --------------------------------------------------------------------------------
  genName :: NameHints -> String
  genName hints = if Set.null hints then "v"
                  else intercalate "_" $ filter (not . null) [prefx, root, sufx]
                  where nms = Set.toList hints
                        prefxs = [nm | x@(NmPrefix _ nm) <- nms]
                        roots  = [nm | x@(NmRoot   _ nm) <- nms]
                        sufxs  = [nm | x@(NmSuffix _ nm) <- nms]
                        prefx  = intercalate "_" prefxs
                        root   = intercalate "_" roots
                        sufx   = intercalate "_" sufxs
  showIntLit :: Int -> Integer -> Doc
  showIntLit w v = int w <> text "'h" <> hexInt v
  showDontCare :: Int -> Doc
  showDontCare w = int w <> text "'b" <> text (replicate w 'x')
  showWire :: (InstId, OutputName) -> Doc
  showWire (iId, m_nm) = text name <> case m_nm of Just nm -> text nm
                                                   _       -> mempty
                                   <> char '_' <> int iId
                            where wNet = netlist Data.Array.IArray.! iId
                                  name = genName $ netNameHints wNet
  showWireWidth :: Int -> (InstId, OutputName) -> Doc
  showWireWidth w wId = brackets (int (w-1) <> text ":0") <+> showWire wId

  showPrim :: Prim -> [NetInput] -> Doc
  showPrim (Const w v) [] = showIntLit w v
  showPrim (DontCare w) [] = showDontCare w
  showPrim (Add _) [e0, e1] = showNetInput e0 <+> char '+' <+> showNetInput e1
  showPrim (Sub _) [e0, e1] = showNetInput e0 <+> char '-' <+> showNetInput e1
  showPrim (Mul _ isSigned _) [e0, e1]
    | isSigned = s0 <> char '*' <> s1
    | otherwise = showNetInput e0 <+> char '*' <+> showNetInput e1
    where
      s0 = text "$signed" <> parens (showNetInput e0)
      s1 = text "$signed" <> parens (showNetInput e1)
  showPrim (Div _) [e0, e1] = showNetInput e0 <+> char '/' <+> showNetInput e1
  showPrim (Mod _) [e0, e1] = showNetInput e0 <+> char '%' <+> showNetInput e1
  showPrim (And _) [e0, e1] = showNetInput e0 <+> char '&' <+> showNetInput e1
  showPrim (Or _)  [e0, e1] = showNetInput e0 <+> char '|' <+> showNetInput e1
  showPrim (Xor _) [e0, e1] = showNetInput e0 <+> char '^' <+> showNetInput e1
  showPrim (Not _) [e0]     = char '~' <> showNetInput e0
  showPrim (ShiftLeft _ _) [e0, e1] =
    showNetInput e0 <+> text "<<" <+> showNetInput e1
  showPrim (ShiftRight _ _) [e0, e1] =
    showNetInput e0 <+> text ">>" <+> showNetInput e1
  showPrim (ArithShiftRight _ _) [e0, e1] =
    text "$signed" <> parens (showNetInput e0) <+> text ">>>" <+> showNetInput e1
  showPrim (Equal _) [e0, e1] = showNetInput e0 <+> text "==" <+> showNetInput e1
  showPrim (NotEqual _) [e0, e1] =
    showNetInput e0 <+> text "!=" <+> showNetInput e1
  showPrim (LessThan _) [e0, e1] =
    showNetInput e0 <+> char '<' <+> showNetInput e1
  showPrim (LessThanEq _) [e0, e1] =
    showNetInput e0 <+> text "<=" <+> showNetInput e1
  showPrim (ReplicateBit w) [e0] = braces $ int w <> braces (showNetInput e0)
  showPrim (ZeroExtend iw ow) [e0] =
    braces $ (braces $ int (ow-iw) <> braces (text "1'b0"))
          <> comma <+> showNetInput e0
  showPrim (SignExtend iw ow) [e0] =
    braces $ (braces $ int (ow-iw)
                    <> braces (showNetInput e0 <> brackets (int (iw-1))))
             <> comma <+> showNetInput e0
  showPrim (SelectBits _ hi lo) [e0] = case e0 of
    InputWire wId -> showWire wId <> brackets (int hi <> colon <> int lo)
    InputTree (Const _ v) [] ->
      showIntLit width ((v `shiftR` lo) .&. ((2^width)-1))
    InputTree (DontCare _) [] -> showDontCare width
    x -> error $
      "unsupported " ++ show x ++ " for SelectBits in Verilog generation"
    where width = hi+1-lo
  showPrim (Concat w0 w1) [e0, e1] =
    braces $ showNetInput e0 <> comma <+> showNetInput e1
  showPrim (Identity w) [e0] = showNetInput e0
  showPrim (MergeWrites MStratOr 0 w) ins = showDontCare w
  showPrim (MergeWrites MStratOr _ w) ins =
    sep $ intersperse (char '|') (f [] ins)
    where f acc [] = acc
          f acc (en:x:rest) = f (parens (f' en x):acc) rest
          f _ _ = error "malformed input list for MergeWrites primitive"
          f' en x = showNetInput en <+> text "== 1 ?" <+> showNetInput x
                                    <+> colon <+> showIntLit w 0
  showPrim p _ = error $
    "unsupported Prim '" ++ show p ++ "' encountered in Verilog generation"

  showNetInput :: NetInput -> Doc
  showNetInput (InputWire wId) = showWire wId
  showNetInput (InputTree p ins) = parens $ showPrim p ins

  -- declaration helpers
  --------------------------------------------------------------------------------
  declWire width wId = text "wire" <+> showWireWidth width wId <> semi
  declWireInit width wId init =     text "wire" <+> showWireWidth width wId
                                <+> equals <+> showIntLit width init <> semi
  declWireDontCare width wId  =     text "wire" <+> showWireWidth width wId
                                <+> equals <+> showDontCare width <> semi
  declReg width reg = text "reg" <+> showWireWidth width reg <> semi
  declRegInit width reg init =
    text "reg" <+> showWireWidth width reg <+>
      case init of
        Nothing -> semi
        Just i -> equals <+> showIntLit width i <> semi
  declMux wsel w net | numIns == 2 && wsel == 1 =
      declWire w (netInstId net, Nothing)
    where numIns = length (netInputs net) - 1
  declMux wsel w net = declWire w (netInstId net, Nothing)
    $+$ hang header 2 body
    $+$ text "endfunction"
    where thisMux = text "mux_" <> int (netInstId net)
          header = text "function" <+> brackets (int (w-1) <> text ":0")
                     <+> thisMux <> parens allArgs <> semi
          selArg = text "input" <+> brackets (int (wsel-1) <> text ":0")
                     <+> text "sel"
          inArgs = [ text "input" <+> brackets (int (w-1) <> text ":0")
                       <+> text "in" <> int i
                   | i <- [0..numIns-1] ]
          allArgs = hcat $ intersperse comma (selArg : inArgs)
          body = hang (text "case" <+> parens (text "sel")) 2
                      (sep $ [ int i <> colon <+> thisMux
                                   <+> equals <+> (text "in" <> int i) <> semi
                             | i <- [0..numIns-1] ] ++ defaultAlt)
                 $+$ text "endcase"
          defaultAlt =
            [ text "default:" <+> thisMux <+> equals <+>
               text (show w ++ "'b" ++ replicate w 'x') <> semi
            | numIns < 2^wsel ]
          numIns = length (netInputs net) - 1
  declRAM initFile 1 _ dw net =
    vcat $ map (\n -> declWire dw (netInstId net, n)) [Nothing]
  declRAM initFile 2 _ dw net =
    vcat $ map (\n -> declWire dw (netInstId net, n)) [Just "DO_A", Just "DO_B"]
  declRAM _ _ _ _ _ = error "cannot declare RAM with more than 2 ports"
  declRegFile RegFileInfo{ regFileId        = id
                         , regFileInitFile  = initFile
                         , regFileAddrWidth = aw
                         , regFileDataWidth = dw } =
        text "reg" <+> brackets (int (dw-1) <> text ":0")
    <+> text "rf" <> int id
    <+> brackets (parens (text "2**" <> int aw) <> text "-1" <> text ":0") <> semi
    <> showInit
    where showInit = case initFile of
            ""    ->     text ""
            fname ->     text "\ngenerate initial $readmemh" <> parens
                         (text fname <> comma <+> text "rf" <> int id) <> semi
                     <+> text "endgenerate"

  -- reset helpers
  --------------------------------------------------------------------------------

  resetRegister width reg Nothing = mempty
  resetRegister width reg (Just init) =
        showWire reg <+> text "<="
    <+> int width <> text "'h" <> hexInt init <> semi

  -- instantiation helpers
  --------------------------------------------------------------------------------
  instPrim net =
        text "assign" <+> showWire (netInstId net, Nothing) <+> equals
    <+> showPrim (netPrim net) (netInputs net) <> semi
  instCustom net name ins outs params clked resetable
    | numParams == 0 = hang (text name) 2 showInst
    | otherwise = hang (hang (text (name ++ "#")) 2 (parens $ argStyle allParams))
                    2 showInst
    where numParams = length params
          showInst = hang (text (name ++ "_") <> int nId) 2 (showArgs <> semi)
          allParams = [ dot <> text key <> parens (text val)
                      | (key :-> val, i) <- zip params [1..] ]
          args = zip (map fst ins) (netInputs net) ++ [ (nm, InputWire (nId, Just nm))
                                                      | nm <- map fst outs ]
          numArgs  = length args
          showArgs = parens $ argStyle $ [ text ".clock(clock)" | clked ]
                                      ++ [ text ".reset(reset)" | resetable ]
                                      ++ allArgs
          allArgs  = [ dot <> text name <> parens (showNetInput netInput)
                     | ((name, netInput), i) <- zip args [1..] ]
          nId = netInstId net
  instTestPlusArgs wId s =
        text "assign" <+> showWire wId <+> equals
    <+> text "$test$plusargs" <> parens (doubleQuotes $ text s)
    <+> text "== 0 ? 0 : 1;"
  instOutput net s =     text "assign" <+> text s
                     <+> equals <+> showNetInput (netInputs net !! 0) <> semi
  instInput net s =     text "assign" <+> showWire (netInstId net, Nothing)
                    <+> equals <+> text s <> semi
  instMux net
    | numIns == 2 = text "assign" <+> showWire (netInstId net, Nothing)
        <+> equals <+> showNetInput (ins!!0) <+> char '?'
        <+> showNetInput (ins!!2) <+> colon <+> showNetInput (ins!!1)
        <> semi
    | otherwise = text "assign" <+> showWire (netInstId net, Nothing)
        <+> equals <+> text "mux_" <> int (netInstId net)
        <> parens args <> semi
    where
      ins = netInputs net
      args = hcat $ intersperse comma $ map showNetInput $ netInputs net
      numIns = length ins - 1
  instRAM net i aw dw be =
        hang (hang (text modName) 2 (parens $ argStyle ramParams)) 2
          (hang (text "ram" <> int nId) 2 ((parens $ argStyle ramArgs) <> semi))
    where prim = netPrim net
          modName = primStr prim ++ "#"
          ramParams = [ text ".INIT_FILE"  <>
                          parens (text (show $ fromMaybe "UNUSED" i))
                      , text ".ADDR_WIDTH" <> parens (int aw)
                      , text ".DATA_WIDTH" <> parens (int dw) ]
          ramArgs   = [ text ".CLK(clock)" ]
                   ++ [ text ('.':arg) <> parens (showNetInput inp)
                      | ((arg, _), inp) <-
                          zip (primInputs prim) (netInputs net) ]
                   ++ [text ".DO" <> parens (showWire (nId, Nothing)) ]
          nId = netInstId net
  instTrueDualRAM net i aw dw be =
        hang (hang (text modName) 2 (parens $ argStyle ramParams)) 2
          (hang (text "ram" <> int nId) 2 ((parens $ argStyle ramArgs) <> semi))
    where prim = netPrim net
          modName = primStr prim ++ "#"
          ramParams = [ text ".INIT_FILE"  <>
                          parens (text (show $ fromMaybe "UNUSED" i))
                      , text ".ADDR_WIDTH" <> parens (int aw)
                      , text ".DATA_WIDTH" <> parens (int dw) ]
          ramArgs   = [ text ".CLK(clock)" ]
                   ++ [ text ('.':arg) <> parens (showNetInput inp)
                      | ((arg, _), inp) <-
                          zip (primInputs prim) (netInputs net) ]
                   ++ [ text ".DO_A" <> parens (showWire (nId, Just "DO_A"))
                      , text ".DO_B" <> parens (showWire (nId, Just "DO_B"))
                      ]
          nId = netInstId net
  instRegFileRead id net =
        text "assign" <+> showWire (netInstId net, Nothing)
    <+> equals <+> text "rf" <> int id
    <>  brackets (showNetInput (netInputs net !! 0)) <> semi

  -- always block helpers
  ------------------------------------------------------------------------------
  alwsRegister net = showWire (netInstId net, Nothing) <+> text "<="
                 <+> showNetInput (netInputs net !! 0) <> semi
  alwsRegisterEn net =
        text "if" <+> parens (showNetInput (netInputs net !! 0) <+> text "== 1")
    <+> showWire (netInstId net, Nothing)
    <+> text "<=" <+> showNetInput (netInputs net !! 1) <> semi
  alwsDisplay args net =
        hang (text "if" <+> parens
                (showNetInput (netInputs net !! 0) <+> text "== 1")
                  <+> text "begin") 2
             (fmtArgs args (tail $ netInputs net)) $+$ text "end"
    where fmtArgs [] _ = mempty
          fmtArgs (DisplayArgString s : args) ins =
                text "$write" <+> parens (text $ show $ escape s) <> semi
            $+$ fmtArgs args ins
          fmtArgs (DisplayArgBit _ r p z : args) (x:ins) =
                text "$write" <+> parens
                  (text (show ("%" ++ fmtPad z p ++ fmtRadix r))
                     <> text "," <+> showNetInput x) <> semi
            $+$ fmtArgs args ins
          fmtArgs (DisplayCondBlockBegin:args) (x:ins) =
              text "if" <+> parens (showNetInput x <+> text "== 1")
                        <+> text "begin"
                        $+$ fmtArgs args ins
          fmtArgs (DisplayCondBlockEnd:args) ins =
            text "end" $+$ fmtArgs args ins

          escape str = concat [if c == '%' then "%%" else [c] | c <- str]

          fmtPad zero Nothing = if zero then "0" else ""
          fmtPad zero (Just x) = (if zero then "0" else "") ++ show x

          fmtRadix Bin = "b"
          fmtRadix Dec = "d"
          fmtRadix Hex = "x"
  alwsFinish net =
    text "if" <+> parens (showNetInput (netInputs net !! 0) <+> text "== 1")
             <+> text "$finish" <> semi
  alwsRegFileWrite id net =
        text "if" <+> parens (showNetInput (netInputs net !! 0) <+> text "== 1")
    <+> text "rf" <> int id <> brackets (showNetInput (netInputs net !! 1))
    <+> text "<=" <+> showNetInput (netInputs net !! 2) <> semi
  alwsAssert Net{netInputs=[cond, pred]} msg =
    hang ifCond 2 (hang ifPred 2 body $+$ text "end") $+$ text "end"
    where
      ifCond = text "if" <+> parens (showNetInput cond <+> text "== 1")
                         <+> text "begin"
      ifPred = text "if" <+> parens (showNetInput pred <+> text "== 0")
                         <+> text "begin"
      body =     text "$write" <> parens (doubleQuotes $ text msg) <> semi
             $+$ text "$finish" <> semi
