%%% $Id$
%%% concrete representation of 2-address pseudo-x86 code

%%% x86 operands:
%%%
%%% int32	::= <a 32-bit integer>
%%% reg		::= <token from hipe_x86_registers module>
%%% type	::= 'tagged' | 'untagged'
%%% label	::= <an integer>
%%% label_type	::= 'label' | 'constant'
%%% aluop	::= <an atom denoting a binary alu op>
%%% term	::= <any Erlang term>
%%% cc		::= <an atom denoting a condition code>
%%% pred	::= <a real number between 0.0 and 1.0 inclusive>
%%% isfail	::= 'true' | 'false'
%%% npop	::= <a 32-bit natural number which is a multiple of 4>
%%%
%%% temp	::= {x86_temp, reg, type, allocatable}
%%% allocatable ::= 'true' | 'false'
%%%
%%% imm		::= {x86_imm, value}
%%% value	::= int32 | atom | {label, label_type}
%%%
%%% mem		::= {x86_mem, base, off, type}
%%% base	::= temp | []		(XXX BUG: not quite true before RA)
%%% off		::= imm | temp
%%%
%%% src		::= temp | mem | imm
%%% dst		::= temp | mem
%%% arg		::= src
%%% args	::= <list of arg>
%%%
%%% mfa		::= {x86_mfa, atom, atom, integer}
%%% prim	::= {x86_prim, atom}
%%% fun		::= mfa | prim | temp | mem
%%%
%%% jtab	::= label	(equiv. to {x86_imm,{label,'constant'}})
%%%
%%% sdesc	::= {x86_sdesc, exnlab, fsize, arity, live}
%%% exnlab	::= [] | label
%%% fsize	::= <int32>		(frame size in words)
%%% live	::= <tuple of int32>	(word offsets)
%%% arity	::= int32

-record(x86_temp, {reg, type, allocatable}).
-record(x86_imm, {value}).
-record(x86_mem, {base, off, type}).
-record(x86_fpreg, {reg, pseudo}).
-record(x86_mfa, {m, f, a}).
-record(x86_prim, {prim}).
-record(x86_sdesc, {exnlab, fsize, arity, live}).

%%% Basic instructions.
%%% These follow the AT&T convention, i.e. op src,dst (dst := dst op src)
%%% After register allocation, at most one operand in a binary
%%% instruction (alu, cmp, move) may denote a memory cell.
%%% After frame allocation, every temp must denote a physical register.

-record(alu, {aluop, src, dst}).
-record(call, {'fun', sdesc}).
-record(cmovcc, {cc, src, dst}).
-record(cmp, {src, dst}).		% a 'sub' alu which doesn't update dst
-record(comment, {term}).
-record(dec, {dst}).
-record(finit, {}).
-record(fmov, {src, dst}).
-record(fop, {op, src, dst}).
-record(inc, {dst}).
-record(jcc, {cc, label}).
-record(jmp_fun, {'fun'}).		% tailcall, direct or indirect
-record(jmp_label, {label}).		% local jmp, direct
-record(jmp_switch, {temp, jtab, labels}).	% local jmp, indirect
-record(label, {label, isfail}).
-record(lea, {mem, temp}).
-record(move, {src, dst}).
-record(movsx, {src, dst}).
-record(movzx, {src, dst}).
-record(nop, {}).
-record(prefix_fs, {}).
-record(pseudo_call, {dsts, 'fun', arity, contlab, exnlab}). % dsts is [] or [EAX]
-record(pseudo_jcc, {cc, true_label, false_label, pred}).
-record(pseudo_tailcall, {'fun', arity, stkargs}).
-record(pseudo_tailcall_prepare, {}).
-record(push, {src}).
-record(ret, {npop}).			% EAX is live-in
%%% Function definitions.

-record(defun, {mfa, formals, code, data, isclosure, isleaf,
		var_range, label_range}).