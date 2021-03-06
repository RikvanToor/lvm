--------------------------------------------------------------------------------
-- Copyright 2001-2012, Daan Leijen, Bastiaan Heeren, Jurriaan Hage. This file 
-- is distributed under the terms of the BSD3 License. For more information, 
-- see the file "LICENSE.txt", which is included in the distribution.
--------------------------------------------------------------------------------
--  $Id$

module Main (main) where

import Control.Monad
import Lvm.Common.Id
import Lvm.Path
import System.Console.GetOpt
import System.Environment
import System.Exit
import System.FilePath
import Text.PrettyPrint.Leijen

import Lvm.Asm.Inline          (asmInline)         -- optimize Asm (ie. local inlining)
import Lvm.Asm.ToLvm           (asmToLvm)          -- translate Asm to Lvm instructions
import Lvm.Core.Module         (modulePublic)      -- imports
import Lvm.Core.Parsing.Layout (layout)            -- apply layout rule
import Lvm.Core.Parsing.Lexer  (lexer)             -- lexical tokens
import Lvm.Core.Parsing.Parser (parseModuleExport) -- parse text into Core
import Lvm.Core.RemoveDead     (coreRemoveDead)    -- remove dead declarations
import Lvm.Core.ToAsm          (coreToAsm)         -- enriched lambda expressions (Core) to Asm
import Lvm.Import              (lvmImport)         -- resolve import declarations
import Lvm.Write               (lvmWriteFile)      -- write a binary Lvm file

----------------------------------------------------------------
--
----------------------------------------------------------------

main :: IO ()
main = do
   args <- getArgs
   case getOpt Permute options args of
      (flags, files, errs)
         | Help `elem` flags -> do
              putStrLn (usageInfo header options)
              exitSuccess
         | Version `elem` flags -> do
              putStrLn ("coreasm, " ++ versionText)
              exitSuccess
         | null errs && not (null files) -> do
              mapM_ (compile flags) files
              exitSuccess
         | otherwise -> do
              putStrLn $ concat errs ++ 
                 "Usage: For basic information, try the --help option."
              exitFailure

versionText :: String
versionText = "version 1.7" -- $Id$"

header :: String
header = 
   "coreasm: The Core Assembler for the Lazy Virtual Machine\n" ++
   "Copyright 2001, Daan Leijen\n" ++
   "\nUsage: coreasm [OPTION] <core modules>\n" ++
   "\nOptions:"

data Flag = Help | Version | Verbosity Verbosity | Dump Dump (Maybe String)
   deriving Eq

data Verbosity = Silent | Normal | Verbose
   deriving (Eq, Ord)

data Dump = DumpTokens | DumpCore | DumpCoreOpt | DumpAsm
          | DumpAsmOpt | DumpInstr
   deriving Eq

getVerbosity :: [Flag] -> Verbosity
getVerbosity flags = 
   case [ a | Verbosity a <- flags ] of
      [] -> Normal 
      xs -> minimum xs

flagVerbose, flagSilent :: Flag
flagVerbose = Verbosity Verbose
flagSilent  = Verbosity Silent

options :: [OptDescr Flag]
options =
     [ simple []  "version"       Version     "show version number"
     , simple "?" "help"          Help        "show options"
     , simple []  "verbose"       flagVerbose "verbose output"
     , simple []  "silent"        flagSilent  "no output"
     , dump "dump-tokens"   DumpTokens  "pretty print tokens"
     , dump "dump-core"     DumpCore    "pretty print core"
     , dump "dump-core-opt" DumpCoreOpt "pretty print core (optimized)"
     , dump "dump-asm"      DumpAsm     "pretty print assembler"
     , dump "dump-asm-opt"  DumpAsmOpt  "pretty print assembler (optimized)"
     , dump "dump-instr"    DumpInstr   "pretty print instructions"
     ]
 where
   simple xs long = Option xs [long] . NoArg
   dump long d    = Option [] [long] (OptArg (Dump d) "file")

findModule :: [String] -> Id -> IO String
findModule paths = searchPath paths ".lvm" . stringFromId

findSrc :: [String] -> String -> IO String
findSrc paths = searchPath paths ".core"

compile :: [Flag] -> FilePath -> IO ()
compile flags srcraw = do
   -- searching
   message flags $ "Compiling " ++ showFile srcraw
   let (srcPath, srcFile, srcExt) = splitFilePath srcraw
   let src = joinPath [srcFile, srcExt]
   
   let path = [srcPath, "."]
   source <- findSrc path src 
   verbose $ "Source file: " ++ showFile source
   
   -- lexing
   verbose "Lexing"
   input  <- readFile source
   let tokens = layout (lexer (1,1) input)
   dumpWith DumpTokens flags "Tokens" tokens
   
   -- parsing
   verbose "Parsing"
   (m, implExps, es) <- parseModuleExport source tokens
   
   -- resolving
   verbose "Resolving imports"
   chasedMod  <- lvmImport (findModule path) m
   let publicmod = modulePublic implExps es chasedMod
   dumpWith DumpCore flags "Core" publicmod
   
   -- compiling
   verbose "Remove dead declarations"
   let coremod = coreRemoveDead publicmod
   dumpWith DumpCoreOpt flags "Core (dead declarations removed)" coremod

   verbose "Generating code"
   nameSupply <- newNameSupply
   
   let asmmod = coreToAsm nameSupply coremod
   dumpWith DumpAsm flags "Assembler" asmmod
   
   let asmopt = asmInline asmmod
   dumpWith DumpAsmOpt flags "Assembler (optimized)" asmopt
   
   let lvmmod = asmToLvm  asmopt
   dumpWith DumpInstr flags "Instructions" lvmmod

   -- writing
   let target  = reverse (dropWhile (/='.') (reverse source)) ++ "lvm"
   message flags $ "Writing " ++ showFile target
   lvmWriteFile target lvmmod

 where
   verbose :: Pretty a => a -> IO () 
   verbose = messageFor Verbose flags

---------------------------------------------------------------------
-- Messages

message :: Pretty a => [Flag] -> a -> IO ()
message = messageFor Normal

messageFor :: Pretty a => Verbosity -> [Flag] -> a -> IO ()
messageFor a flags = 
   when (getVerbosity flags >= a) . messageDoc

messageDoc :: Pretty a => a -> IO ()
messageDoc = print . pretty

dumpWith :: Pretty a => Dump -> [Flag] -> String -> a -> IO () 
dumpWith dump flags s a = 
   case [ mf | Dump d mf <- flags, d == dump ] of
      Just file:_ -> do message flags ("Writing " ++ file)
                        writeFile file (show (pretty a))
      Nothing:_   -> messageDoc nice
      []          -> return ()
 where
   nice  = vsep [hline, pretty ("-- " ++ s), empty, pretty a, hline]
   hline = pretty (replicate 40 '-')

showFile :: String -> String
showFile = map (\c -> if c == '\\' then '/' else c)