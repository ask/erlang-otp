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
#ifdef __WIN32__
#include <winsock2.h>
#include <windows.h>
#include <winbase.h>

#elif VXWORKS
#include <unistd.h>

#else /* unix */
#include <unistd.h>

#endif

#include <string.h>
#include <stdlib.h>
#include "eidef.h"
#include "eiext.h"
#include "eisend.h"
#include "ei_internal.h"
#include "putget.h"
#include "show_msg.h"

/* FIXME this is not used ! */

/* this sends either link or unlink ('which' decides) */
static int link_unlink(int fd, const erlang_pid *from, const erlang_pid *to, int which)
{
  char msgbuf[EISMALLBUF];
  char *s;
  int index = 0;
  int n;

  index = 5;                                     /* max sizes: */
  ei_encode_version(msgbuf,&index);                     /*   1 */
  ei_encode_tuple_header(msgbuf,&index,3);
  ei_encode_long(msgbuf,&index,which);
  ei_encode_pid(msgbuf,&index,from);                    /* 268 */
  ei_encode_pid(msgbuf,&index,to);                      /* 268 */

  /* 5 byte header missing */
  s = msgbuf;
  put32be(s, index - 4);                                /*   4 */
  put8(s, ERL_PASS_THROUGH);                            /*   1 */
                                                  /* sum:  542 */


#ifdef DEBUG_DIST
  if (ei_trace_distribution > 1) ei_show_sendmsg(stderr,msgbuf,NULL);
#endif

  n = writesocket(fd,msgbuf,index); 

  return (n==index ? 0 : -1);
}

/* FIXME not used? */
#if 0
/* use this to send a link */
int ei_send_unlink(int fd, const erlang_pid *from, const erlang_pid *to)
{
  return link_unlink(fd, from, to, ERL_UNLINK);
}

/* use this to send an unlink */
int ei_send_link(int fd, const erlang_pid *from, const erlang_pid *to)
{
  return link_unlink(fd, from, to, ERL_LINK);
}
#endif