{-*-----------------------------------------------------------------------
  The Core Assembler.

  Copyright 2001, Daan Leijen. All rights reserved. This file
  is distributed under the terms of the GHC license. For more
  information, see the file "license.txt", which is included in
  the distribution.
-----------------------------------------------------------------------*-}

-- $Id$

module CoreToAsm( coreToAsm ) where

import Id     ( Id, idFromString, NameSupply, splitNameSupplies )
import IdMap  ( IdMap, listFromMap, mapFromList )
import IdSet  ( IdSet, elemSet, setFromMap )
import Core
import qualified Asm

import CoreNoShadow   ( coreNoShadow )    -- rename local variables
import CoreSaturate   ( coreSaturate )    -- saturate constructors, instructions and externs
import CoreNormalize  ( coreNormalize )   -- normalize core, ie. atomic arguments and lambda's at let bindings
import CoreFreeVar    ( coreFreeVar )     -- attach free variable information at let bindings
import CoreLetSort    ( coreLetSort )     -- find smallest recursive let binding groups
import CoreLift       ( coreLift )        -- lambda-lift, ie. make free variables arguments


{---------------------------------------------------------------
  coreToAsm: translate Core expressions into Asm expressions
---------------------------------------------------------------}
coreToAsm :: NameSupply -> CoreModule -> Asm.AsmModule
coreToAsm supply mod
  = exprToTop
  $ coreLift
  $ coreLetSort
  $ coreFreeVar
  $ coreNormalize supply2
  $ coreSaturate supply1
  $ coreNoShadow supply0
  $ mod
  where
    (supply0:supply1:supply2:supplies) = splitNameSupplies supply

exprToTop :: CoreModule -> Asm.AsmModule
exprToTop mod
  = mod{ values = concatMap (asmDValue primitives) (values mod) }
  where
    primitives  = setFromMap (externs mod)


{---------------------------------------------------------------
  top-level bindings
---------------------------------------------------------------}
asmDValue prim (id,DValue acc enc expr custom)
  = let (pars,(lifted,asmexpr)) = asmTop prim expr
    in (id,DValue acc enc (Asm.Top pars asmexpr) custom) : concatMap (asmLifted prim id) lifted

asmLifted prim enc (Bind id expr)
  = let (pars,(lifted,asmexpr)) = asmTop prim expr
    in  (id,DValue Private (Just enc) (Asm.Top pars asmexpr) []) : concatMap (asmLifted prim id) lifted


asmTop prim expr
  = let (pars,expr') = splitParams expr
    in (pars,asmExpr prim expr')

splitParams :: Expr -> ([Id],Expr)
splitParams expr
  = case expr of
      Note n e  -> splitParams e
      Lam x e   -> let (pars,e') = splitParams e in (x:pars,e')
      other     -> ([],expr)

{---------------------------------------------------------------
  expressions
---------------------------------------------------------------}
asmExpr :: IdSet -> Expr -> ([Bind],Asm.Expr)
asmExpr prim expr
  = case expr of
      Note n e        -> asmExpr prim e
      Lam x e         -> error "CoreToAsm.asmExpr: unexpected lambda expression (do 'coreNormalise' first?)"
      Let binds e     -> asmLet prim binds (asmExpr prim e)

      Case e id [Alt PatDefault expr]
                      -> let (lifted0,asme)    = asmExpr prim e
                             (lifted1,asmexpr) = asmExpr prim expr
                         in  (lifted0++lifted1,Asm.Eval id asme asmexpr)
      Case e id alts  -> let (lifted0,asmexpr) = asmExpr prim e
                             (lifted1,asmalts) = asmAlts prim alts
                         in  (lifted0++concat lifted1,Asm.Eval id asmexpr (Asm.Match id asmalts))

      atom            -> let asmatom = asmAtom atom []  -- handles prim ap's too
                         in case asmatom of
                              Asm.Ap id args  | elemSet id prim
                                              -> ([],Asm.Prim id args)
                              other           -> ([],Asm.Atom asmatom)

asmAlts prim alts
  = unzip (map (asmAlt prim) alts)

asmAlt prim (Alt pat expr)
  = let (lifted,asmexpr) = asmExpr prim expr
    in (lifted, Asm.Alt (asmPat pat) asmexpr)

asmPat pat
  = case pat of
      PatCon id params  -> Asm.PatCon id params
      PatLit lit        -> Asm.PatLit (asmLit lit)
      PatDefault        -> Asm.PatVar (idFromString  ".def")

asmLet prim binds (lifted,asmexpr)
  = case binds of
      NonRec bind@(Bind id expr)
                -> if (isAtomic prim expr)
                    then (lifted, Asm.Let id (asmAtom expr []) asmexpr)
                    else (Bind id expr:lifted,asmexpr)
      Rec binds -> let (lifted',binds') = foldr asmRec (lifted,[]) binds
                   in if (null binds')
                       then (lifted',asmexpr)
                       else (lifted',Asm.LetRec binds' asmexpr)
  where
    asmRec bind@(Bind id expr) (lifted,binds)
      | isAtomic prim expr = (lifted,(id,asmAtom expr []):binds)
      | otherwise          = (bind:lifted,binds)


{---------------------------------------------------------------
 atomic expressions & primitive applications
---------------------------------------------------------------}
asmAtom atom args
  = case atom of
      Note n e  -> asmAtom e args
      Ap e1 e2  -> asmAtom e1 (asmAtom e2 []:args)
      Var id    -> Asm.Ap id args
      Con id    -> Asm.Con id args
      Lit lit   | null args -> Asm.Lit (asmLit lit)
      other     -> error "CoreToAsm.asmAtom: non atomic expression (do 'coreNormalise' first?)"

asmLit lit
  = case lit of
     LitInt i    -> Asm.LitInt i
     LitDouble d -> Asm.LitFloat d
     LitBytes s  -> Asm.LitBytes s

{---------------------------------------------------------------
  is an expression atomic ?
---------------------------------------------------------------}
isAtomic prim expr
  = case expr of
      Note n e  -> isAtomic prim e
      Ap e1 e2  -> isAtomic prim e1 && isAtomic prim e2
      Var id    -> not (elemSet id prim)
      Con id    -> True
      Lit lit   -> True
      other     -> False