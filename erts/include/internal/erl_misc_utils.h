/*
 * %CopyrightBegin%
 * 
 * Copyright Ericsson AB 2006-2009. All Rights Reserved.
 * 
 * The contents of this file are subject to the Erlang Public License,
 * Version 1.1, (the "License"); you may not use this file except in
 * compliance with the License. You should have received a copy of the
 * Erlang Public License along with this software. If not, it can be
 * retrieved online at http://www.erlang.org/.
 * 
 * Software distributed under the License is distributed on an "AS IS"
 * basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
 * the License for the specific language governing rights and limitations
 * under the License.
 * 
 * %CopyrightEnd%
 */

#ifndef ERL_MISC_UTILS_H_
#define ERL_MISC_UTILS_H_

#include "erl_errno.h"

typedef struct erts_cpu_info_t_ erts_cpu_info_t;
typedef struct {
    int node;
    int processor;
    int core;
    int thread;
    int logical;
} erts_cpu_topology_t;

erts_cpu_info_t *erts_cpu_info_create(void);
void erts_cpu_info_destroy(erts_cpu_info_t *cpuinfo);
void erts_cpu_info_update(erts_cpu_info_t *cpuinfo);
int erts_get_cpu_configured(erts_cpu_info_t *cpuinfo);
int erts_get_cpu_online(erts_cpu_info_t *cpuinfo);
int erts_get_cpu_available(erts_cpu_info_t *cpuinfo);
char *erts_get_unbind_from_cpu_str(erts_cpu_info_t *cpuinfo);
int erts_get_available_cpu(erts_cpu_info_t *cpuinfo, int no);
int erts_get_cpu_topology(erts_cpu_info_t *cpuinfo,
			  erts_cpu_topology_t *topology);
int erts_is_cpu_available(erts_cpu_info_t *cpuinfo, int id);
int erts_bind_to_cpu(erts_cpu_info_t *cpuinfo, int cpu);
int erts_unbind_from_cpu(erts_cpu_info_t *cpuinfo);
int erts_unbind_from_cpu_str(char *str);

int erts_milli_sleep(long);

#endif /* #ifndef ERL_MISC_UTILS_H_ */
