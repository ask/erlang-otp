/*
 * $Id$
 */
#include "hipe_bif0.h"	/* for stack descriptor stuff */
#include "hipe_x86_asm.h"	/* for X86_NR_ARG_REGS */

/* Emulated code recursively calls native code.
   The return address is `nbif_return', which is exported so that
   tailcalls from native to emulated code can be identified. */
extern unsigned int x86_call_to_native(Process*);
extern void nbif_return(void);

/* Native-mode stubs for calling emulated-mode closures. */
extern void nbif_ccallemu0(void);
extern void nbif_ccallemu1(void);
extern void nbif_ccallemu2(void);
extern void nbif_ccallemu3(void);
extern void nbif_ccallemu4(void);
extern void nbif_ccallemu5(void);

/* Default exception handler for native code. */
extern void nbif_fail(void);

/* Emulated code returns to its native code caller. */
extern unsigned int x86_return_to_native(Process*);

/* Emulated code tailcalls native code. */
extern unsigned int x86_tailcall_to_native(Process*);

/* Emulated code throws an exception to its native code caller. */
extern unsigned int x86_throw_to_native(Process*);

static __inline__ void hipe_arch_glue_init(void)
{
    static struct sdesc_with_exnra nbif_return_sdesc = {
	.exnra = (unsigned long)nbif_fail,
	.sdesc = {
	    .bucket = { .hvalue = (unsigned long)nbif_return },
	    .summary = (1<<8),
	},
    };
    hipe_init_sdesc_table(&nbif_return_sdesc.sdesc);
}

/* PRE: arity <= X86_NR_ARG_REGS */
static __inline__ void
hipe_write_x86_regs(Process *p, unsigned int arity, Eterm reg[])
{
#if X86_NR_ARG_REGS > 0
    int i;
    for(i = arity; --i >= 0;)
	p->def_arg_reg[i] = reg[i];
#endif
}

/* PRE: arity <= X86_NR_ARG_REGS */
static __inline__ void
hipe_read_x86_regs(Process *p, unsigned int arity, Eterm reg[])
{
#if X86_NR_ARG_REGS > 0
    int i;
    for(i = arity; --i >= 0;)
	reg[i] = p->def_arg_reg[i];
#endif
}

static __inline__ void
hipe_push_x86_params(Process *p, unsigned int arity, Eterm reg[])
{
    unsigned int i;

    i = arity;
    if( i > X86_NR_ARG_REGS ) {
	Eterm *nsp = p->hipe.nsp;
	i = X86_NR_ARG_REGS;
	do {
	    *--nsp = reg[i++];
	} while( i < arity );
	p->hipe.nsp = nsp;
	i = X86_NR_ARG_REGS;
    }
    /* INV: i <= X86_NR_ARG_REGS */
    hipe_write_x86_regs(p, i, reg);
}

static __inline__ void
hipe_pop_x86_params(Process *p, unsigned int arity, Eterm reg[])
{
    unsigned int i;

    i = arity;
    if( i > X86_NR_ARG_REGS ) {
	Eterm *nsp = p->hipe.nsp;
	do {
	    reg[--i] = *nsp++;
	} while( i > X86_NR_ARG_REGS );
	p->hipe.nsp = nsp;
	/* INV: i == X86_NR_ARG_REGS */
    }
    /* INV: i <= X86_NR_ARG_REGS */
    hipe_read_x86_regs(p, i, reg);
}

/* BEAM recursively calls native code. */
static __inline__ unsigned int
hipe_call_to_native(Process *p, unsigned int arity, Eterm reg[])
{
    int nstkargs;

    /* Note that call_to_native() needs two words on the stack:
       one for the nbif_return return address, and one for the
       callee's return address should it need to call inc_stack_0. */
    if( (nstkargs = arity - X86_NR_ARG_REGS) < 0 )
	nstkargs = 0;
    hipe_check_nstack(p, nstkargs+1+1);
    hipe_push_x86_params(p, arity, reg);	/* needs nstkargs words */
    return x86_call_to_native(p);		/* needs 1+1 words */
}

/* Native called BEAM, which now tailcalls native. */
static __inline__ unsigned int
hipe_tailcall_to_native(Process *p, unsigned int arity, Eterm reg[])
{
    int nstkargs;

    if( (nstkargs = arity - X86_NR_ARG_REGS) < 0 )
	nstkargs = 0;
    hipe_check_nstack(p, nstkargs+1);	/* +1 so callee can call inc_stack_0 */
    if( nstkargs ) {
	Eterm nra;
	nra = *(p->hipe.nsp++);
	hipe_push_x86_params(p, arity, reg);
	*--(p->hipe.nsp) = nra;
    } else
	hipe_write_x86_regs(p, arity, reg);
    return x86_tailcall_to_native(p);
}

/* BEAM called native, which has returned. Clean up. */
static __inline__ void hipe_return_from_native(Process *p) { }

/* BEAM called native, which has thrown an exception. Clean up. */
static __inline__ void hipe_throw_from_native(Process *p) { }

/* BEAM called native, which now calls BEAM.
   Move the parameters to reg[].
   Return zero if this is a tailcall, non-zero if the call is recursive.
   If tailcall, also clean up native stub continuation. */
static __inline__ int
hipe_call_from_native_is_recursive(Process *p, Eterm reg[])
{
    Eterm nra;

    nra = *(p->hipe.nsp++);
    hipe_pop_x86_params(p, p->arity, reg);
    if( nra != (Eterm)nbif_return ) {
	*--(p->hipe.nsp) = nra;
	return 1;
    }
    return 0;
}

/* Native called BEAM, which now returns back to native. */
static __inline__ unsigned int hipe_return_to_native(Process *p)
{
    return x86_return_to_native(p);
}

/* Native called BEAM, which now throws an exception back to native. */
static __inline__ unsigned int hipe_throw_to_native(Process *p)
{
    return x86_throw_to_native(p);
}

/* Native called a BIF which failed with RESCHEDULE.
   Move the parameters to a safe place. */
static __inline__ void hipe_reschedule_from_native(Process *p)
{
#if X86_NR_ARG_REGS == 0
    ASSERT(p->arity == 0);
#else
    if( p->arg_reg != p->def_arg_reg ) {
	unsigned int i;
	for(i = 0; i < p->arity; ++i)
	    p->arg_reg[i] = p->def_arg_reg[i];
    }
#endif
}

/* Resume a BIF call which had failed with RESCHEDULE. */
static __inline__ unsigned int
hipe_reschedule_to_native(Process *p, unsigned int arity, Eterm reg[])
{
#if X86_NR_ARG_REGS == 0
    ASSERT(arity == 0);
    return x86_tailcall_to_native(p);
#else
    p->arity = 0;
    return hipe_tailcall_to_native(p, arity, reg);
#endif
}

/* Return the address of a stub switching a native closure call to BEAM. */
static __inline__ void *hipe_closure_stub_address(unsigned int arity)
{
#if X86_NR_ARG_REGS == 0
    return nbif_ccallemu0;
#else	/* > 0 */
    switch( arity ) {
      case 0:	return nbif_ccallemu0;
#if X86_NR_ARG_REGS == 1
      default:	return nbif_ccallemu1;
#else	/* > 1 */
      case 1:	return nbif_ccallemu1;
#if X86_NR_ARG_REGS == 2
      default:	return nbif_ccallemu2;
#else	/* > 2 */
      case 2:	return nbif_ccallemu2;
#if X86_NR_ARG_REGS == 3
      default:	return nbif_ccallemu3;
#else	/* > 3 */
      case 3:	return nbif_ccallemu3;
#if X86_NR_ARG_REGS == 4
      default:	return nbif_ccallemu4;
#else	/* > 4 */
      case 4:	return nbif_ccallemu4;
#if X86_NR_ARG_REGS == 5
      default:	return nbif_ccallemu5;
#else	/* > 5 */
#error "X86_NR_ARG_REGS > 5 NOT YET IMPLEMENTED"
#endif	/* > 5 */
#endif	/* > 4 */
#endif	/* > 3 */
#endif	/* > 2 */
#endif	/* > 1 */
    }
#endif	/* > 0 */
}