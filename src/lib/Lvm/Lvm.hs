{------------------------------------------------------------------------
  The Core Assembler.

  Copyright 2001, Daan Leijen. All rights reserved. This file
  is distributed under the terms of the GHC license. For more
  information, see the file "license.txt", which is included in
  the distribution.
------------------------------------------------------------------------}

--  $Id$

module Lvm.Lvm( module Lvm.Module, LvmModule, LvmDecl

          -- constants
          , recHeader,recFooter           
          ) where

import Lvm.Instr   ( Instr )
import Lvm.Module

{--------------------------------------------------------------
  An LVM module
---------------------------------------------------------------}
type LvmModule  = Module [Instr]
type LvmDecl    = Decl [Instr]

{---------------------------------------------------------------
  Constants
---------------------------------------------------------------}
recHeader,recFooter :: Int
recHeader     = 0x1F4C564D
recFooter     = 0x1E4C564D