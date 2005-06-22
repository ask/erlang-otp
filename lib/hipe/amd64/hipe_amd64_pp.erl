%%% -*- erlang-indent-level: 2 -*-
%%% $Id$

-define(HIPE_X86_PP,        hipe_amd64_pp).
-define(HIPE_X86_REGISTERS, hipe_amd64_registers).
-define(HIPE_X86_PP_MOVE64(Dev, I),
	#move64{imm=Src, dst=Dst} = I,
	io:format(Dev, "\tmov64 ", []),
	pp_src(Dev, Src),
	io:format(Dev, ", ", []),
	pp_dst(Dev, Dst),
	io:format(Dev, "\n", [])).

-include("../x86/hipe_x86_pp.erl").