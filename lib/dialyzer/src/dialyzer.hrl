%%% This is an -*- Erlang -*- file.
%%%-------------------------------------------------------------------
%%% File    : dialyzer.hrl
%%% Author  : Tobias Lindahl <tobiasl@csd.uu.se>
%%%           Kostis Sagonas <kostis@it.uu.se>
%%% Description : Header file for the Dialyzer.
%%%
%%% Created : 1 Oct 2004 by Kostis Sagonas <kostis@it.uu.se>
%%%-------------------------------------------------------------------

-define(RET_NOTHING_SUSPICIOUS, 0).
-define(RET_INTERNAL_ERROR, 1).
-define(RET_DISCREPANCIES_FOUND, 2).

-define(WARN_CALLGRAPH, warn_callgraph).

-define(SRC_COMPILE_OPTS, 
	[to_core, binary, report_errors, no_inline, strict_record_tests]).
-define(HIPE_DEF_OPTS, 
	[no_inline_fp, {pmatch, no_duplicates}, {target, x86}]).

-record(analysis, {analysis_pid, core_transform=cerl_typean,
		   defines=[], doc_plt,
		   files, fixpoint, granularity, include_dirs=[],
		   init_plt, mcg=none, plt_info=none, 
		   supress_inline, start_from, user_plt}).

-record(options, {files=[],
		  files_rec=[],
		  core_transform=cerl_typean,
		  defines=[],
		  from=byte_code, %% default is to start from byte code	  
		  init_plt,
		  include_dirs=[],
		  output_plt,
		  legal_warnings,
		  plt_libs=none,
		  supress_inline=false,
		  output_file=""}).