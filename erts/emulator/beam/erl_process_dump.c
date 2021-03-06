/*
 * %CopyrightBegin%
 * 
 * Copyright Ericsson AB 2003-2009. All Rights Reserved.
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

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "erl_process.h"
#include "error.h"
#include "bif.h"
#include "erl_db.h"
#include "dist.h"
#include "beam_catches.h"
#include "erl_binary.h"

#define WORD_FMT "%X"
#define ADDR_FMT "%X"

#define OUR_NIL	_make_header(0,_TAG_HEADER_FLOAT)

static void dump_process_info(int to, void *to_arg, Process *p);
static void dump_element(int to, void *to_arg, Eterm x);
static void dump_element_nl(int to, void *to_arg, Eterm x);
static int stack_element_dump(int to, void *to_arg, Process* p, Eterm* sp,
			      int yreg);
static void print_function_from_pc(int to, void *to_arg, Eterm* x);
static void heap_dump(int to, void *to_arg, Eterm x);
static void dump_binaries(int to, void *to_arg, Binary* root);
static void dump_externally(int to, void *to_arg, Eterm term);

static Binary* all_binaries;

extern Eterm beam_apply[];
extern Eterm beam_exit[];
extern Eterm beam_continue_exit[];


void
erts_deep_process_dump(int to, void *to_arg)
{
    int i;

    all_binaries = NULL;
    
    for (i = 0; i < erts_max_processes; i++) {
	if ((process_tab[i] != NULL) && (process_tab[i]->i != ENULL)) {
	   if (process_tab[i]->status != P_EXITING) {
	       Process* p = process_tab[i];

	       if (p->status != P_GARBING) {
		   dump_process_info(to, to_arg, p);
	       }
	   }
       }
    }

    dump_binaries(to, to_arg, all_binaries);
}

static void
dump_process_info(int to, void *to_arg, Process *p)
{
    Eterm* sp;
    ErlMessage* mp;
    int yreg = -1;

    ERTS_SMP_MSGQ_MV_INQ2PRIVQ(p);

    if ((p->trace_flags & F_SENSITIVE) == 0 && p->msg.first) {
	erts_print(to, to_arg, "=proc_messages:%T\n", p->id);
	for (mp = p->msg.first; mp != NULL; mp = mp->next) {
	    Eterm mesg = ERL_MESSAGE_TERM(mp);
	    dump_element(to, to_arg, mesg);
	    mesg = ERL_MESSAGE_TOKEN(mp);
	    erts_print(to, to_arg, ":");
	    dump_element(to, to_arg, mesg);
	    erts_print(to, to_arg, "\n");
	}
    }

    if ((p->trace_flags & F_SENSITIVE) == 0) {
	if (p->dictionary) {
	    erts_print(to, to_arg, "=proc_dictionary:%T\n", p->id);
	    erts_deep_dictionary_dump(to, to_arg,
				      p->dictionary, dump_element_nl);
	}
    }

    if ((p->trace_flags & F_SENSITIVE) == 0) {
	erts_print(to, to_arg, "=proc_stack:%T\n", p->id);
	for (sp = p->stop; sp < STACK_START(p); sp++) {
	    yreg = stack_element_dump(to, to_arg, p, sp, yreg);
	}

	erts_print(to, to_arg, "=proc_heap:%T\n", p->id);
	for (sp = p->stop; sp < STACK_START(p); sp++) {
	    Eterm term = *sp;
	    
	    if (!is_catch(term) && !is_CP(term)) {
		heap_dump(to, to_arg, term);
	    }
	}
	for (mp = p->msg.first; mp != NULL; mp = mp->next) {
	    Eterm mesg = ERL_MESSAGE_TERM(mp);
	    heap_dump(to, to_arg, mesg);
	    mesg = ERL_MESSAGE_TOKEN(mp);
	    heap_dump(to, to_arg, mesg);
	}
	if (p->dictionary) {
	    erts_deep_dictionary_dump(to, to_arg, p->dictionary, heap_dump);
	}
    }
}

static void
dump_element(int to, void *to_arg, Eterm x)
{
    if (is_list(x)) {
	erts_print(to, to_arg, "H" WORD_FMT, list_val(x));
    } else if (is_boxed(x)) {
	erts_print(to, to_arg, "H" WORD_FMT, boxed_val(x));
    } else if (is_immed(x)) {
	if (is_atom(x)) {
	    unsigned char* s = atom_tab(atom_val(x))->name;
	    int len = atom_tab(atom_val(x))->len;
	    int i;

	    erts_print(to, to_arg, "A%X:", atom_tab(atom_val(x))->len);
	    for (i = 0; i < len; i++) {
		erts_putc(to, to_arg, *s++);
	    }
	} else if (is_small(x)) {
	    erts_print(to, to_arg, "I%T", x);
	} else if (is_pid(x)) {
	    erts_print(to, to_arg, "P%T", x);
	} else if (is_port(x)) {
	    erts_print(to, to_arg, "p<%bpu.%bpu>",
		       port_channel_no(x), port_number(x));
	} else if (is_nil(x)) {
	    erts_putc(to, to_arg, 'N');
	}
    }
}

static void
dump_element_nl(int to, void *to_arg, Eterm x)
{
    dump_element(to, to_arg, x);
    erts_putc(to, to_arg, '\n');
}


static int
stack_element_dump(int to, void *to_arg, Process* p, Eterm* sp, int yreg)
{
    Eterm x = *sp;

    if (yreg < 0 || is_CP(x)) {
        erts_print(to, to_arg, "%p:", sp);
    } else {
        erts_print(to, to_arg, "y%d:", yreg);
        yreg++;
    }

    if (is_CP(x)) {
        erts_print(to, to_arg, "SReturn addr 0x%X (", (Eterm *) x);
        print_function_from_pc(to, to_arg, cp_val(x));
        erts_print(to, to_arg, ")\n");
        yreg = 0;
    } else if is_catch(x) {
        erts_print(to, to_arg, "SCatch 0x%X (", catch_pc(x));
        print_function_from_pc(to, to_arg, catch_pc(x));
        erts_print(to, to_arg, ")\n");
    } else {
	dump_element(to, to_arg, x);
	erts_putc(to, to_arg, '\n');
    }
    return yreg;
}

static void
print_function_from_pc(int to, void *to_arg, Eterm* x)
{
    Eterm* addr = find_function_from_pc(x);
    if (addr == NULL) {
        if (x == beam_exit) {
            erts_print(to, to_arg, "<terminate process>");
        } else if (x == beam_continue_exit) {
            erts_print(to, to_arg, "<continue terminate process>");
        } else if (x == beam_apply+1) {
            erts_print(to, to_arg, "<terminate process normally>");
        } else {
            erts_print(to, to_arg, "unknown function");
        }
    } else {
	erts_print(to, to_arg, "%T:%T/%bpu + %bpu",
		   addr[0], addr[1], addr[2], ((x-addr)-2) * sizeof(Eterm));
    }
}

static void
heap_dump(int to, void *to_arg, Eterm x)
{
    Eterm* ptr;
    Eterm last = OUR_NIL;
    Eterm* next = &last;

    if (is_immed(x) || is_CP(x)) {
	return;
    }

 again:
    if (x == OUR_NIL) {	/* We are done. */
	return;
    } if (is_CP(x)) {
	next = (Eterm *) x;
    } else if (is_list(x)) {
	ptr = list_val(x);
	if (ptr[0] != OUR_NIL) {
	    erts_print(to, to_arg, ADDR_FMT ":l", ptr);
	    dump_element(to, to_arg, ptr[0]);
	    erts_putc(to, to_arg, '|');
	    dump_element(to, to_arg, ptr[1]);
	    erts_putc(to, to_arg, '\n');
	    if (is_immed(ptr[1])) {
		ptr[1] = make_small(0);
	    }
	    x = ptr[0];
	    ptr[0] = (Eterm) next;
	    next = ptr + 1;
	    goto again;
	}
    } else if (is_boxed(x)) {
	Eterm hdr;
	
	ptr = boxed_val(x);
	hdr = *ptr;
	if (hdr != OUR_NIL) {	/* If not visited */
	    erts_print(to, to_arg, ADDR_FMT ":", ptr);
	    if (is_arity_value(hdr)) {
		Uint i;
		Uint arity = arityval(hdr);

		erts_print(to, to_arg, "t" WORD_FMT ":", arity);
		for (i = 1; i <= arity; i++) {
		    dump_element(to, to_arg, ptr[i]);
		    if (is_immed(ptr[i])) {
			ptr[i] = make_small(0);
		    }
		    if (i < arity) {
			erts_putc(to, to_arg, ',');
		    }
		}
		erts_putc(to, to_arg, '\n');
		if (arity == 0) {
		    ptr[0] = OUR_NIL;
		} else {
		    x = ptr[arity];
		    ptr[0] = (Eterm) next;
		    next = ptr + arity - 1;
		    goto again;
		}
	    } else if (hdr == HEADER_FLONUM) {
		FloatDef f;
		char sbuf[31];
		int i;

		GET_DOUBLE_DATA((ptr+1), f);
		i = sys_double_to_chars(f.fd, (char*) sbuf);
		sys_memset(sbuf+i, 0, 31-i);
		erts_print(to, to_arg, "F%X:%s\n", i, sbuf);
		*ptr = OUR_NIL;
	    } else if (_is_bignum_header(hdr)) {
		erts_print(to, to_arg, "B%T\n", x);
		*ptr = OUR_NIL;
	    } else if (is_binary_header(hdr)) {
		Uint tag = thing_subtag(hdr);
		Uint size = binary_size(x);
		Uint i;

		if (tag == HEAP_BINARY_SUBTAG) {
		    byte* p;

		    erts_print(to, to_arg, "Yh%X:", size);
		    p = binary_bytes(x);
		    for (i = 0; i < size; i++) {
			erts_print(to, to_arg, "%02X", p[i]);
		    }
		} else if (tag == REFC_BINARY_SUBTAG) {
		    ProcBin* pb = (ProcBin *) binary_val(x);
		    Binary* val = pb->val;

		    if (erts_smp_atomic_xchg(&val->refc, 0) != 0) {
			val->flags = (Uint) all_binaries;
			all_binaries = val;
		    }
		    erts_print(to, to_arg, "Yc%X:%X:%X", val,
			       pb->bytes - (byte *)val->orig_bytes,
			       size);
		} else if (tag == SUB_BINARY_SUBTAG) {
		    ErlSubBin* Sb = (ErlSubBin *) binary_val(x);
		    Eterm* real_bin = binary_val(Sb->orig);
		    void* val;

		    if (thing_subtag(*real_bin) == REFC_BINARY_SUBTAG) {
			ProcBin* pb = (ProcBin *) real_bin;
			val = pb->val;
		    } else {	/* Heap binary */
			val = real_bin;
		    }
		    erts_print(to, to_arg, "Ys%X:%X:%X", val, Sb->offs, size);
		}
		erts_putc(to, to_arg, '\n');
		*ptr = OUR_NIL;
	    } else if (is_external_pid_header(hdr)) {
		erts_print(to, to_arg, "P%T\n", x);
		*ptr = OUR_NIL;
	    } else if (is_external_port_header(hdr)) {
		erts_print(to, to_arg, "p<%bpu.%bpu>\n",
			   port_channel_no(x), port_number(x));
		*ptr = OUR_NIL;
	    } else {
		/*
		 * All other we dump in the external term format.
		 */
		dump_externally(to, to_arg, x);
		erts_putc(to, to_arg, '\n');
		*ptr = OUR_NIL;
	    }
	}
    }

    x = *next;
    *next = OUR_NIL;
    next--;
    goto again;
}

static void
dump_binaries(int to, void *to_arg, Binary* current)
{
    while (current) {
	long i;
	long size = current->orig_size;
	byte* bytes = (byte*) current->orig_bytes;

	erts_print(to, to_arg, "=binary:%X\n", current);
	erts_print(to, to_arg, "%X:", size);
	for (i = 0; i < size; i++) {
	    erts_print(to, to_arg, "%02X", bytes[i]);
	}
	erts_putc(to, to_arg, '\n');
	current = (Binary *) current->flags;
    }
}

static void
dump_externally(int to, void *to_arg, Eterm term)
{
    byte sbuf[1024]; /* encode and hope for the best ... */
    byte* s; 
    byte* p;

    if (is_fun(term)) {
	/*
	 * The fun's environment used to cause trouble. There were
	 * two kind of problems:
	 *
	 * 1. A term used in the environment could already have been
	 *    dumped and thus destroyed (since dumping is destructive).
	 *
	 * 2. A term in the environment could be too big, so that
	 *    the buffer for external format overflowed (allocating
	 *    memory is not really a solution, as it could be exhausted).
	 *
	 * Simple solution: Set all variables in the environment to NIL.
	 * The crashdump_viewer does not allow inspection of them anyway.
	 */
	ErlFunThing* funp = (ErlFunThing *) fun_val(term);
	Uint num_free = funp->num_free;
	Uint i;

	for (i = 0; i < num_free; i++) {
	    funp->env[i] = NIL;
	}
    }

    s = p = sbuf;
    erts_to_external_format(NULL, term, &p, NULL, NULL);
    erts_print(to, to_arg, "E%X:", p-s);
    while (s < p) {
	erts_print(to, to_arg, "%02X", *s++);
    }
}
