{-*-----------------------------------------------------------------------
  The Core Assembler.

  Copyright 2001, Daan Leijen. All rights reserved. This file
  is distributed under the terms of the GHC license. For more
  information, see the file "license.txt", which is included in
  the distribution.
-----------------------------------------------------------------------*-}

-- $Id$

module CoreParse( coreParse ) where

import Parsec hiding (satisfy)
import Byte   ( bytesFromString )
import Id     ( Id, stringFromId, idFromString )
import IdMap
import IdSet
import Core
import CoreLexer


----------------------------------------------------------------
-- Parse a Core source file
----------------------------------------------------------------
coreParse :: FilePath -> IO (CoreModule,IdSet)
coreParse fname
  = do{ input  <- readFile fname
      ; case runParser parseModule () fname (layout (lexer (1,1) input)) of
          Left err
            -> ioError (userError ("parse error: " ++ show err))
          Right res
            -> return res
      }

----------------------------------------------------------------
-- Basic parsers
----------------------------------------------------------------
type TokenParser a  = GenParser Token () a

----------------------------------------------------------------
-- Types
----------------------------------------------------------------
data Type       = TFun    {tp1::Type, tp2::Type}
                | TAp     {tp1::Type, tp2::Type}
                | TForall {tpId::Id, tp::Type}
                | TExist  {tpId::Id, tp::Type}
                | TStrict {tp::Type}
                | TVar    {tpId::Id}
                | TCon    {tpId::Id}
                | TAny
                | TString {tpString::String}

data Kind       = KFun {kind1::Kind, kind2::Kind}
                | KStar
                | KString {kindString::String}

data SuperKind  = Box

arityFromType :: Type -> Int
arityFromType tp
  = case tp of
      TFun    t1 t2   -> arityFromType t2 + 1
      TAp     t1 t2   -> 0                     -- assumes saturated constructors!
      TForall id t    -> arityFromType t
      TExist  id t    -> arityFromType t
      TStrict t       -> arityFromType t
      TVar    id      -> 0
      TCon    id      -> 0
      TAny            -> 0
      TString s       -> error "Core.arityFromType: string type"

arityFromKind :: Kind -> Int
arityFromKind kind
  = case kind of
      KFun    k1 k2   -> arityFromKind k1 + 1
      KStar           -> 0
      KString s       -> error "Core.arityFromKind: string kind"


----------------------------------------------------------------
-- Program
----------------------------------------------------------------
parseModule :: TokenParser (CoreModule, IdSet)
parseModule
  = do{ lexeme LexMODULE
      ; moduleId <- conid <?> "module name"
      ; lexeme LexWHERE
      ; lexeme LexLBRACE
      ; imports  <- semiTerm pimport
      ; externs  <- semiTerm pextern
      ; conDs    <- semiTerm pdata
      ; types    <- semiTerm ptypeTopDecl
      ; ds       <- semiList ptopDecl
      ; lexeme LexRBRACE
      ; lexeme LexEOF

      ; let externDecls           = mapFromList (externs)
            conDecls              = mapFromList (concat conDs)
            importDecls           = setFromList imports
      ; return (Module moduleId 0 0 ds emptyMap conDecls externDecls emptyMap, importDecls)
      }


----------------------------------------------------------------
-- import declarations
----------------------------------------------------------------
pimport :: TokenParser Id
pimport
  = do{ lexeme LexIMPORT
      ; conid
      }

----------------------------------------------------------------
-- value declarations
----------------------------------------------------------------
ptopDecl :: TokenParser (Id,CoreValue)
ptopDecl
  = do{ id <- variable
      ; ptopDeclType id <|> ptopDeclDirect id
      }

ptopDeclType id
  = do{ (tp,arity) <- ptypeDecl
      ; lexeme LexSEMI
      ; id'  <- variable
      ; if (id /= id')
         then fail "identifier for type signature doesn't match the definition"
         else return ()
      ; expr <- pbindRhs
      ; return (id, DValue Public Nothing expr [])
      }

ptopDeclDirect id
  = do{ expr <- pbindRhs
      ; return (id,DValue Public Nothing expr [])
      }
  where
    typeFromExpr expr
      = TString ""


pbind :: TokenParser Bind
pbind
  = do{ id   <- variable
      ; expr <- pbindRhs
      ; return (Bind id expr)
      }

pbindRhs
  = do{ args <- many bindid
      ; lexeme LexASG
      ; body <- pexpr
      ; let expr = foldr Lam body args
      ; return expr
      }
  <?> "declaration"

----------------------------------------------------------------
-- data declarations
----------------------------------------------------------------
pdata :: TokenParser [(Id,DCon)]
pdata
  = do{ lexeme LexDATA
      ; id   <- typeid
      ; args <- many typevarid
      ; let kind            = foldr KFun KStar (map (const KStar) args)
      ; do{ lexeme LexASG
          ; let tp  = foldl TAp (TCon id) (map TVar args)
          ; cons <- sepBy1 (pconDecl tp) (lexeme LexBAR)
          ; let con tag (id,tp) = (id,DCon Public (arityFromType tp) tag [])
          ; return (zipWith con [0..] cons)
          }
      <|> {- empty data types -}
        do{ return ([]) }
      }

pconDecl :: Type -> TokenParser (Id,Type)
pconDecl tp
  = do{ id   <- constructor
      ; args <- many ptypeAtom
      ; return (id,foldr TFun tp args)
      }

----------------------------------------------------------------
-- type declarations
----------------------------------------------------------------
ptypeTopDecl :: TokenParser ()
ptypeTopDecl
  = do{ lexeme LexTYPE
      ; id   <- typeid
      ; args <- many typevarid
      ; lexeme LexASG
      ; tp   <- ptype
      ; let kind = foldr KFun KStar (map (const KStar) args)
      ; return ()
      }

----------------------------------------------------------------
-- Expressions
----------------------------------------------------------------
pexpr
  = do{ lexeme LexBSLASH
      ; args <- many bindid
      ; lexeme LexRARROW
      ; expr <- pexpr
      ; return (foldr Lam expr args)
      }
  <|>
    do{ lexeme LexLET
      ; binds <- semiBraces pbind
      ; lexeme LexIN
      ; expr  <- pexpr
      ; return (Let (Rec binds) expr)
      }
  <|>
    do{ lexeme LexCASE
      ; expr <- pexpr
      ; lexeme LexOF
      ; (id,alts) <- palts
      ; return (Case expr id alts)
      }
  <|> pexprAp
  <?> "expression"

pexprAp
  = do{ atoms <- many1 patom
      ; return (foldl1 Ap atoms)
      }

patom
  =   do{ id <- varid; return (Var id)  }
  <|> do{ id <- conid; return (Con id)  }
  <|> do{ lit <- pliteral; return (Lit lit) }
  <|> parenExpr
  <?> "atomic expression"

parenExpr
  = do{ lexeme LexLPAREN
      ; do{ lexeme LexRPAREN
          ; id <- identifier (return "()")
          ; return (Con id)
          }
      <|>
        do{ id <- opid
          ; lexeme LexRPAREN
          ; return (Var id)
          }
      <|>
        do{ id <- conopid
          ; lexeme LexRPAREN
          ; return (Con id)
          }
      <|>
        do{ expr <- pexpr
          ; lexeme LexRPAREN
          ; return expr
          }
      }


pliteral
  =   pnumber id id
  <|> do{ s <- lexString; return (LitBytes (bytesFromString s)) }
  <|> do{ c <- lexChar;   return (LitInt (fromEnum c))   }
  <|> do{ lexeme LexDASH
        ; pnumber negate negate
        }
  <?> "literal"

pnumber signint signdouble
  =   do{ i <- lexInt;    return (LitInt (signint (fromInteger i))) }
  <|> do{ d <- lexDouble; return (LitDouble (signdouble d)) }

----------------------------------------------------------------
-- alternatives
----------------------------------------------------------------
palts :: TokenParser (Id,Alts)
palts
  = do{ lexeme LexLBRACE
      ; (id,alts) <- paltSemis
      ; return (id,alts)
      }

paltSemis :: TokenParser (Id,Alts)
paltSemis
  = do{ (id,alt) <- paltDefault
      ; optional (lexeme LexSEMI)
      ; lexeme LexRBRACE
      ; return (id,[alt])
      }
  <|>
    do{ alt <- paltTagCon <|> paltLit
      ;   do{ lexeme LexSEMI
            ;     do{ (id,alts) <- paltSemis
                    ; return (id,alt:alts)
                    }
              <|> do{ lexeme LexRBRACE
                    ; id <- wildcard
                    ; return (id,[alt])
                    }
            }
      <|> do{ lexeme LexRBRACE
            ; id <- wildcard
            ; return (id,[alt])
            }
      }


paltTagCon
  = do{ id   <- constructor
      ; args <- many bindid
      ; lexeme LexRARROW
      ; expr <- pexpr
      ; return (Alt (PatCon id args) expr)
      }


paltLit
  = do{ lit <- pliteral
      ; lexeme LexRARROW
      ; expr <- pexpr
      ; return (Alt (PatLit lit) expr)
      }

paltDefault
  = do{ id <- bindid <|> do{ lexeme LexDEFAULT; wildcard }
      ; lexeme LexRARROW
      ; expr <- pexpr
      ; return (id,Alt PatDefault expr)
      }

wildcard :: TokenParser Id
wildcard
  = identifier (return "_")

----------------------------------------------------------------
-- externs
----------------------------------------------------------------
pextern :: TokenParser (Id,DExtern)
pextern
  = do{ lexeme LexEXTERN
      ; linkConv <- plinkConv
      ; callConv <- pcallConv
      ; id  <- varid
      ; mod <- lexString <|> return (stringFromId id)
      ; (modname,name) <- pExternName mod
      ; (TString tp,arity)  <- do{ lexeme LexCOLCOL; ptypeString } -- ptypeDecl
      ; return (id,DExtern Public arity tp linkConv callConv modname name [])
      }
  <|>
    do{ lexeme LexINSTR
      ; id <- varid
      ; s  <- lexString
      ; (tp,arity) <- ptypeDecl
      ; return (id,DExtern Public arity "" LinkStatic CallInstr "" (Plain s) [])
      }

------------------

plinkConv
  =   do{ lexeme LexSTATIC; return LinkStatic }
  <|> do{ lexeme LexDYNAMIC; return LinkDynamic }
  <|> do{ lexeme LexRUNTIME; return LinkRuntime }
  <|> return LinkStatic

pcallConv
  =   do{ lexeme LexCCALL; return CallC }
  <|> do{ lexeme LexSTDCALL; return CallStd }
  <|> do{ lexeme LexINSTRCALL; return CallInstr }
  <|> return CallC

pExternName modname
  =   do{ lexeme LexDECORATE
        ; name <- lexString
        ; return (modname,Decorate name)
        }
  <|> do{ lexeme LexORDINAL
        ; ord  <- lexInt
        ; return (modname,Ordinal (fromIntegral ord))
        }
  <|> do{ name <- lexString
        ; return (modname,Plain name)
        }
  <|> return ("",Plain modname)


----------------------------------------------------------------
-- types
----------------------------------------------------------------
ptypeDecl
  = do{ lexeme LexCOLCOL
      ; ptypeNormal <|> ptypeString
      }

ptypeNormal
  = do{ tp <- ptype
      ; return (tp,arityFromType tp)
      }


ptype :: TokenParser Type
ptype
  = ptypeFun

ptypeFun
  = chainr1 ptypeAp pFun
  where
    pFun  = do{ lexeme LexRARROW; return TFun }

ptypeAp
  = do{ atoms <- many1 ptypeAtom
      ; return (foldl1 TAp atoms)
      }

ptypeAtom
  = do{ id <- typeid
      ; do{ lexeme LexEXCL
          ; return (TStrict (TCon id))
          }
        <|> return (TCon id)
      }
  <|>
    do{ id <- typevarid
      ; return (TVar id)
      }
  <|> listType
  <|> parenType
  <?> "atomic type"

parenType
  = do{ lexeme LexLPAREN
      ; do{ lexeme LexRPAREN
          ; id <- identifier (return "()")
          ; return (TVar id) -- (setSortId SortType id))
          }
      <|>
        do{ tp <- ptype
          ; lexeme LexRPAREN
          ; return tp
          }
      }

listType
  = do{ lexeme LexLBRACKET
      ; do{ tp <- ptype
          ; lexeme LexRBRACKET
          ; id <- identifier (return "[]")
          ; return (TAp (TCon id {- (setSortId SortType id) -}) tp)
          }
      <|>
        do{ lexeme LexRBRACKET
          ; id <- identifier (return "[]")
          ; return (TCon id {-(setSortId SortType id)-})
          }
      }

ptypeString
  = do{ s <- lexString
      ; return (TString s, length s-1)
      }


pKind :: TokenParser Kind
pKind
  = pkindFun

pkindFun
  = chainr1 pkindAtom pFun
  where
    pFun  = do{ lexeme LexRARROW; return KFun }

pkindAtom
  =   pStar
  <|> parens pKind

pStar
  = do{ op <- lexOp
      ; if (op /= "*")
         then fail ("invalid kind: " ++ show op)
         else return KStar
      }

----------------------------------------------------------------
-- helpers
----------------------------------------------------------------
semiBraces p  = braces (semiList p)
braces p      = between (lexeme LexLBRACE) (lexeme LexRBRACE) p
parens p      = between (lexeme LexLPAREN) (lexeme LexRPAREN) p

-- terminated or seperated
semiList1 p
    = do{ x <- p
        ; do{ lexeme LexSEMI
            ; xs <- semiList p
            ; return (x:xs)
            }
          <|> return [x]
        }

semiList p
    = semiList1 p <|> return []

semiTerm p
    = many (do{ x <- p; lexeme LexSEMI; return x })

----------------------------------------------------------------
-- Lexeme parsers
----------------------------------------------------------------
variable
  = varid <|> parens opid

opid
  = identifier lexOp
  <?> "operator"

varid
  =   identifier lexId
  <?> "variable"

bindid :: TokenParser Id
bindid
  = do{ id <- varid
      ; do{ lexeme LexEXCL
          ; return id {- (setSortId SortStrict id) -}
          }
        <|> return id
      }

constructor
  = conid <|> parens conopid

conopid
  = identifier lexConOp
  <?> "constructor operator"

conid
  =   identifier lexCon
  <|> do{ lexeme LexLBRACKET
        ; lexeme LexRBRACKET
        ; identifier (return "[]")
        }
  <?> "constructor"


typeid
  = do{ id <- identifier lexCon
      ; return id -- (setSortId SortType id)
      }
  <?> "type"

typevarid
  = do{ id <- identifier lexId
      ; return id -- (setSortId SortType id)
      }

identifier p
  = do{ s <- p
      ; return (idFromString s)
      }

----------------------------------------------------------------
-- Basic parsers
----------------------------------------------------------------
lexeme :: Lexeme -> TokenParser Lexeme
lexeme lex
  = satisfy (\lex' -> if (lex == lex') then Just lex else Nothing) <?> show lex


lexChar :: TokenParser Char
lexChar
  = satisfy (\lex -> case lex of { LexChar c -> Just c; other -> Nothing })

lexString :: TokenParser String
lexString
  = satisfy (\lex -> case lex of { LexString s -> Just s; other -> Nothing })

lexDouble :: TokenParser Double
lexDouble
  = satisfy (\lex -> case lex of { LexFloat d -> Just d; other -> Nothing })

lexInt :: TokenParser Integer
lexInt
  = satisfy (\lex -> case lex of { LexInt i -> Just i; other -> Nothing })

lexId :: TokenParser String
lexId
  = satisfy (\lex -> case lex of { LexId s -> Just s; other -> Nothing })

lexOp :: TokenParser String
lexOp
  = satisfy (\lex -> case lex of { LexOp s -> Just s; other -> Nothing })

lexCon :: TokenParser String
lexCon
  = satisfy (\lex -> case lex of { LexCon s -> Just s; other -> Nothing })

lexConOp :: TokenParser String
lexConOp
  = satisfy (\lex -> case lex of { LexConOp s -> Just s; other -> Nothing })

satisfy :: (Lexeme -> Maybe a) -> TokenParser a
satisfy pred
  = tokenPrim showtok nextpos (\(pos,lex) -> pred lex)
  where
    showtok (pos,lex)   = show lex
    nextpos pos _ (((line,col),lex):_)
       = setSourceColumn (setSourceLine pos line) col
    nextpos pos _ []
       = pos