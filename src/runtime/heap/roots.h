/***********************************************************************/
/*                                                                     */
/*                           Objective Caml                            */
/*                                                                     */
/*         Xavier Leroy and Damien Doligez, INRIA Rocquencourt         */
/*                                                                     */
/*  Copyright 1996 Institut National de Recherche en Informatique et   */
/*  en Automatique.  All rights reserved.  This file is distributed    */
/*  under the terms of the GNU Library General Public License.         */
/*                                                                     */
/***********************************************************************/

/***---------------------------------------------------------------------
  Modified and adapted for the Lazy Virtual Machine by Daan Leijen.
  Modifications copyright 2001, Daan Leijen. This (modified) file is
  distributed under the terms of the GNU Library General Public License.
---------------------------------------------------------------------***/

/* $Id$ */

#ifndef _roots_
#define _roots_

#include "misc.h"
#include "memory.h"

struct fixed_block;
struct thread_state;

typedef void (*scanning_action) (value, value *);

void oldify_local_roots (void);
void darken_all_roots (void);
void do_roots (scanning_action);
#ifndef NATIVE_CODE
void do_local_roots (scanning_action f,
                     struct thread_state* threads,
                     struct fixed_block*  fixed_blocks,
                     struct caml__roots_block *local_roots);
#else
void do_local_roots(scanning_action f, char * bottom_of_stack,
                    unsigned long last_retaddr, value * gc_regs,
                    struct caml__roots_block * local_roots);
#endif

extern void (*scan_roots_hook) (scanning_action);

#endif /* _roots_ */
