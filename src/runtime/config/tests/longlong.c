/***********************************************************************/
/*                                                                     */
/*                           Objective Caml                            */
/*                                                                     */
/*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         */
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

#include <stdio.h>
#include <string.h>

/* Check for the availability of "long long" type as per ISO C9X */

int main(int argc, char **argv)
{
  long long l;
  unsigned long long u;
  char buffer[64];

  if (sizeof(long long) == 8) {
    l = 123456789123456789LL;
    buffer[0] = 0;
    sprintf (buffer, "%lld", l);
    if (strcmp(buffer, "123456789123456789") == 0) return 1;
    /* the MacOS X library uses qd to format long longs */
    buffer[0] = '\0';
    sprintf (buffer, "%qd", l);
    if (strcmp (buffer, "123456789123456789") == 0) return 2;
    return 0; /* gcc -mno-cygwin can't print 64 bit integers */
  }
  else
    return 100;
}
