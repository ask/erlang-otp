/* ``The contents of this file are subject to the Erlang Public License,
 * Version 1.1, (the "License"); you may not use this file except in
 * compliance with the License. You should have received a copy of the
 * Erlang Public License along with this software. If not, it can be
 * retrieved via the world wide web at http://www.erlang.org/.
 * 
 * Software distributed under the License is distributed on an "AS IS"
 * basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
 * the License for the specific language governing rights and limitations
 * under the License.
 * 
 * The Initial Developer of the Original Code is Ericsson Utvecklings AB.
 * Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
 * AB. All Rights Reserved.''
 * 
 *     $Id$
 */
#include "erl_error.h"
#include "ei.h"
#include "putget.h"

/* remove version identifier from the start of the buffer */
int 
ei_decode_version (const char *buf, int *index, int *version)
{
  const char *s = buf + *index;
  const char *s0 = s;
  int v;
  
  v = get8(s);
  if (version) *version = v;
  if (v != ERL_VERSION_MAGIC)
  {
      erl_errno = EIO;
      return -1;
  }
  
  *index += s-s0;
  
  return 0;
}
