%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Initial Developer of the Original Code is Ericsson Utvecklings AB.
%% Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
%% AB. All Rights Reserved.''
%% 
%%     $Id$
%%
-module(snmp_mib_data).

%%%-----------------------------------------------------------------
%%% This module implements the MIB internal data structures.
%%% An MIB Data Structure consists of three items; an ets-table,
%%% a tree and a list of registered subagents.
%%% The subagent information is consequently duplicated. It resides
%%% both in the tree and in the list.
%%% The ets-table contains all data associated with each variable,
%%% table, tableentry and tablecolumn in the MIB.
%%% The tree contains information of the Oids in the MIB.
%%%
%%% When a mib is loaded, the tree is built from the plain list
%%% in the binary file.
%%%-----------------------------------------------------------------
-include("snmp_types.hrl").
-include("snmp_debug.hrl").

-define(VMODULE,"MDATA").
-include("snmp_verbosity.hrl").


-ifdef(snmp_debug).
-define(store(N,T),store(N,T)).
-else.
-define(store(N,T),ok).
-endif.

%%%-----------------------------------------------------------------
%%% Table of contents
%%% =================
%%% 1. Interface
%%% 2. Implementation of tree access
%%% 3. Tree building functions
%%% 4. Tree merging
%%% 5. Tree deletion routines
%%% 6. Functions for subagent handling
%%% 7. Misc functions
%%%-----------------------------------------------------------------


%%----------------------------------------------------------------------
%% mibsEts is an ets containing loaded mibs as:
%%    {MibName = atom(), FullFileName = string()}
%% tree is the root node.
%% subagents is a list of {SAPid, Oid}
%%----------------------------------------------------------------------
-record(snmp_mib_data, {mibsEts, tree, subagents = []}).

%% API
-export([new/0, load_mib/4, unload_mib/4, unload_all/1, info/1, info/2,
	 dump/1, dump/2, lookup/2, next/3,
	 register_subagent/3, unregister_subagent/2]).

%% Internal exports
-export([merge_nodes/2,drop_internal_and_imported/1,call_instrumentation/2,
	 code_change/2]).

%%-----------------------------------------------------------------
%% A tree is represented as a N-tuple, where each element is a
%% node. A node is:
%% 1) {tree, Tree, Info} where Info can be {table, Id}, {table_entry, Id}
%%                                        or perhaps 'internal'
%% 2) undefined_node  (memory optimization (instead of {node, undefined}))
%% 3) {node, Info} where Info can be {subagent, Pid}, {variable, Id}, 
%%                                   {table_column, Id}
%% Id is {MibName, MibEntry}
%% The over all root is represented as {tree, Tree, internal}.
%%
%% tree() = {tree, nodes(), tree_info()}
%% nodes() = {tree() | node() | undefined_node, ...}
%% node() = {node, node_info()}
%% tree_info() = {table, Id} | {table_entry, Id} | internal
%% node_info() = {subagent, Pid} | {variable, Id} | {table_colum, Id}
%%-----------------------------------------------------------------

%%%======================================================================
%%% 1. Interface
%%%======================================================================

%%-----------------------------------------------------------------
%% Func: new/1
%% Returns: A representation of mib data.
%%-----------------------------------------------------------------
new() ->
    MibsEts = ets:new(snmp_mib_data, [set, protected]),    
    #snmp_mib_data{mibsEts = MibsEts, tree = {tree,{undefined_node},internal}}.

%%----------------------------------------------------------------------
%% Returns: new mib data | {error, Reason}
%%----------------------------------------------------------------------
load_mib(MibData,FileName,MeOverride,TeOverride) when record(MibData,snmp_mib_data),list(FileName) -> 
    ?vlog("load mib file: ~p",[FileName]),
    #snmp_mib_data{mibsEts = MibsEts, tree = OldRoot} = MibData,
    ActualFileName = filename:rootname(FileName, ".bin") ++ ".bin",
    MibName = list_to_atom(filename:basename(FileName, ".bin")),
    case ets:lookup(MibsEts, MibName) of
	[{MibName, _, _}] -> {error, 'already loaded'};
	[] ->
	    case snmp_misc:read_mib(ActualFileName) of
		{error, Reason} -> 
		    ?vlog("Failed reading mib file ~p with reason: ~p",
			  [ActualFileName,Reason]),
		    {error, Reason};
		{ok, Mib} ->
		    ?vtrace("loaded mib ~s",[Mib#mib.name]),
		    NonInternalMes = 
			lists:filter(fun drop_internal_and_imported/1,
				     Mib#mib.mes),
		    ?vdebug("~n   ~w mib-entries of which ~w "
			    "are non internal or imported",
			    [length(Mib#mib.mes),length(NonInternalMes)]),
		    T = build_tree(NonInternalMes, MibName),
		    case catch merge_nodes(T, OldRoot) of
			{error_merge_nodes, Node1, Node2} ->
			    ?vlog("error merging nodes ~p and ~p",
				  [Node1,Node2]),
			    {error, oid_conflict};
			NewRoot when tuple(NewRoot),element(1,NewRoot)==tree->
			    Symbolic = not lists:member(no_symbolic_info,
							Mib#mib.misc),
			    case check_notif_and_mes(TeOverride,
						     MeOverride,
						     Symbolic, 
						     Mib#mib.traps,
						     NonInternalMes) of
				true ->
				    install_mib(Symbolic, Mib, MibName,
						ActualFileName,
						MibsEts, NonInternalMes),
				    ?vtrace("installed mib ~s",
					    [Mib#mib.name]),
				    MibData#snmp_mib_data{tree = NewRoot};
				Else -> Else
			    end
		    end
	    end
    end.

%%----------------------------------------------------------------------
%% Returns: true | {error, Reason}
%% (OTP-3601)
%%----------------------------------------------------------------------
check_notif_and_mes(TeOverride,MeOverride,Symbolic,Traps,MEs) ->
    ?vtrace("check notifications and mib entries",[]),
    check_mes(MeOverride,check_notifications(TeOverride,Symbolic,Traps),MEs).

check_notifications(true, _Symbolic, _Traps) ->
    ?vtrace("trapentry override = true => skip check",[]),
    true;
check_notifications(_, Symbolic, Traps) -> 
    check_notifications(Symbolic, Traps).

check_notifications(true, Traps) ->
    check_notifications(Traps);
check_notifications(_, _) -> true.

check_notifications([]) -> true;
check_notifications([Trap | Traps]) ->
    Key = Trap#trap.trapname,
    ?vtrace("check notification with Key: ~p",[Key]),
    case snmp_symbolic_store:get_notification(Key) of
	{value, Trap} -> check_notifications(Traps);
	{value, _} -> {error, {'trap already defined', Key}};
	undefined -> check_notifications(Traps)
    end.

check_mes(true,_,_) ->
    ?vtrace("mibentry override = true => skip check",[]),
    true; 
check_mes(_,true,MEs) ->
    check_mes(MEs);
check_mes(_,Else,_MEs) ->
    Else.

check_mes([ME | MEs]) ->
    Name = ME#me.aliasname,
    Oid1 = ME#me.oid,
    ?vtrace("check mib entries with aliasname: ~p",[Name]),
    case snmp_symbolic_store:aliasname_to_oid(Name) of
	{value, Oid1} -> check_mes(MEs);
	{value, Oid2} -> 
	    ?vinfo("~n   expecting '~p'~n   but found '~p'",[Oid1,Oid2]),
	    {error, {'mibentry already defined', Name}};
	false -> check_mes(MEs)
    end;
check_mes([]) -> true.


%%----------------------------------------------------------------------
%% Returns: new mib data | {error, Reason}
%%----------------------------------------------------------------------
unload_mib(MibData, FileName, _, _)
  when record(MibData, snmp_mib_data), list(FileName) -> 
    #snmp_mib_data{mibsEts = MibsEts, tree = OldRoot} = MibData,
    ActualFileName = filename:rootname(FileName, ".bin") ++ ".bin",
    MibName = list_to_atom(filename:basename(FileName, ".bin")),
    case ets:lookup(MibsEts, MibName) of
	[] -> {error, 'not loaded'};
	[{MibName, Symbolic, _}] ->
	    {MEs, NewRoot} = delete_mib_from_tree(MibName,OldRoot),
	    uninstall_mib(Symbolic, MibName, MibsEts, MEs),
	    MibData#snmp_mib_data{tree = NewRoot}
    end.

unload_all(#snmp_mib_data{mibsEts = MibsEts}) ->
    lists:foreach(fun({MibName, Symbolic, _}) ->
			  uninstall_mib(Symbolic, MibName, MibsEts, [])
		  end, ets:tab2list(MibsEts)).

register_subagent(MibData, Oid, Pid) ->
    case insert_subagent(Oid, Pid, MibData#snmp_mib_data.tree) of
	{error, Reason} -> {error, Reason};
	NewTree ->
	    MibData#snmp_mib_data{tree = NewTree,
				  subagents=[{Pid, Oid}
					     | MibData#snmp_mib_data.subagents]}
    end.

%%----------------------------------------------------------------------
%% Purpose: Deletes SA with Pid from all subtrees it handles.
%% Returns: NewMibData.
%%----------------------------------------------------------------------
unregister_subagent(MibData, Pid) when pid(Pid) ->
    SAs = MibData#snmp_mib_data.subagents,
    case lists:keysearch(Pid, 1, SAs) of
	false -> MibData;
	{value, {Pid, Oid}} ->
	    % we should never get an error since Oid is found in MibData.
	    {ok, NewMibData, _DeletedSA} = unregister_subagent(MibData, Oid),
	    % continue if the same Pid handles other mib subtrees.
	    unregister_subagent(NewMibData, Pid)
    end;

%%----------------------------------------------------------------------
%% Purpose: Deletes one unique subagent. 
%% Returns: {error, Reason} | {ok, NewMibData, DeletedSubagentPid}
%%----------------------------------------------------------------------
unregister_subagent(MibData, Oid) when list(Oid) ->
    case catch delete_subagent(MibData#snmp_mib_data.tree, Oid) of
	{tree, Tree, Info} ->
	    OldSAs = MibData#snmp_mib_data.subagents,
	    {value, {Pid, _Oid}} = lists:keysearch(Oid, 2, OldSAs),
	    SAs = lists:keydelete(Oid, 2, OldSAs),
	    {ok, 
	     MibData#snmp_mib_data{tree = {tree, Tree, Info}, subagents = SAs},
	     Pid};
	Error ->
	    {error, {'invalid oid', Oid}}
    end.

%%----------------------------------------------------------------------
%% Purpose: To inpect memory usage, loaded mibs, registered subagents
%%----------------------------------------------------------------------
info(MibData) ->
    #snmp_mib_data{mibsEts = MibsEts, tree = Tree, subagents = SAs} = MibData,
    LoadedMibs = ets:tab2list(MibsEts),
    TreeSize = snmp_misc:mem_size(Tree),
    [{loaded_mibs, LoadedMibs}, {subagents, SAs}, {tree_size_bytes, TreeSize}].

info(MibData, subagents) ->
    #snmp_mib_data{subagents = SAs} = MibData,
    SAs.

%%----------------------------------------------------------------------
%% A total dump for debugging.
%%----------------------------------------------------------------------
dump(MibData) when record(MibData, snmp_mib_data) -> 
    #snmp_mib_data{mibsEts = MibsEts, tree = Tree} = MibData,
    io:format("MIB-table:~n~p~n~n", [ets:tab2list(MibsEts)]),
    io:format("Tree:~n~p~n", [Tree]), % good luck reading it!
    ok.

dump(MibData,File) when record(MibData, snmp_mib_data) -> 
    case file:open(File,[write]) of
	{ok,Fd} ->
	    #snmp_mib_data{mibsEts = MibsEts, tree = Tree} = MibData,
	    io:format(Fd,"~s~n", 
		      [snmp:date_and_time_to_string(snmp:date_and_time())]),
	    io:format(Fd,"MIB-table:~n~p~n~n", [ets:tab2list(MibsEts)]),
	    io:format(Fd,"Tree:~n~p~n", [Tree]), % good luck reading it!
	    file:close(Fd),
	    ok;
	{error,Reason} ->
	    ?vinfo("~n   Failed opening file '~s' for reason ~p",
		   [File,Reason]),
	    {error,Reason}
    end.


%%%======================================================================
%%% 2. Implementation of tree access
%%%    lookup and next.
%%%======================================================================

%%-----------------------------------------------------------------
%% Func: lookup/2
%% Purpose: Finds the mib entry corresponding to the Oid. If it is a
%%          variable, the Oid must be <Oid for var>.0 and if it is
%%          a table, Oid must be <table>.<entry>.<col>.<any>
%% Returns: {variable, MibEntry} |
%%          {table_column, MibEntry, TableEntryOid} |
%%          {subagent, SubAgentPid, SAOid} |
%%          false
%%-----------------------------------------------------------------
lookup(#snmp_mib_data{tree = Tree}, Oid) ->
    case catch find_node(Tree, Oid, []) of
	{variable, ME} when record(ME, me) -> 
	    {variable, ME};
	{table, EntryME, {ColME, RevTableEntryOid}} ->
	    MFA = EntryME#me.mfa,
	    RetME = ColME#me{mfa = MFA},
	    {table_column, RetME, lists:reverse(RevTableEntryOid)};
	{subagent, SubAgentPid, SANextOid} ->
	    {subagent, SubAgentPid, SANextOid};
	{false, ErrorCode} -> {false, ErrorCode};
	{'EXIT', _} -> {false, noSuchObject}
    end.

find_node({tree, Tree, {table, _Id}}, RestOfOid, RevOid) ->
    find_node({tree, Tree, internal}, RestOfOid, RevOid);
find_node({tree, Tree, {table_entry,{_MibName, EntryME}}},RestOfOid, RevOid) ->
    case find_node({tree, Tree, internal}, RestOfOid, RevOid) of
	{false, ErrorCode} -> {false, ErrorCode};
	Val -> {table, EntryME, Val}
    end;
find_node({tree, Tree, _Internal}, [Int | RestOfOid], RevOid) ->
    find_node(element(Int+1, Tree), RestOfOid, [Int | RevOid]);
find_node({node, {table_column,{_,ColumnME}}}, RestOfOid, [ColInt | RevOid]) ->
    {ColumnME, RevOid};
find_node({node, {variable, {_MibName, VariableME}}}, [0], _RevOid) ->
    {variable, VariableME};
find_node({node, {variable, {_MibName, VariableME}}}, [], _RevOid) ->
    {false, noSuchObject};
find_node({node, {variable, {_MibName, VariableME}}}, _, _RevOid) ->
    {false, noSuchInstance};
find_node({node, {subagent, SubAgentPid}}, _RestOfOid, SARevOid) ->
    {subagent, SubAgentPid, lists:reverse(SARevOid)};
find_node(_Node, _RestOfOid, _RevOid) ->
    {false, noSuchObject}.


%%-----------------------------------------------------------------
%% Func: next/3
%% Purpose: Finds the lexicographically next oid.
%% Returns: endOfMibView |
%%          {subagent, SubAgentPid, SAOid} |
%%          {variable, MibEntry, VarOid} |
%%          {table, TableOid, TableRestOid, MibEntry}
%% If a variable is returnes, it is in the MibView.
%% If a table or subagent is returned, it *may* be in the MibView.
%%-----------------------------------------------------------------
next(#snmp_mib_data{tree = RootNode}, Oid, MibView) ->
    case catch next_node(RootNode, Oid, [], MibView) of
	false -> endOfMibView;
	Else -> Else
    end.

%%-----------------------------------------------------------------
%% This function is used as long as we have any Oid left. Take
%% one integer at a time from the Oid, and traverse the tree
%% accordingly. When the Oid is empty, call find_next.
%% Returns: {subagent, SubAgentPid, SAOid} |
%%          false |
%%          {variable, MibEntry, VarOid} |
%%          {table, TableOid, TableRestOid, MibEntry}
%%-----------------------------------------------------------------
next_node(undefined_node, _Oid, _RevOidSoFar, _MibView) ->
    false;

next_node({tree, Tree, {table_entry, _Id}}, [Int | Oid], RevOidSoFar, _MibView)
  when Int+1 > size(Tree) ->
    false;
next_node({tree, Tree, {table_entry, {_MibName, EntryME}}},
	  Oid, RevOidSoFar, MibView) ->
    OidSoFar = lists:reverse(RevOidSoFar),
    case snmp_acm:is_definitely_not_in_mib_view(OidSoFar, MibView) of
	true -> false;
	_ -> {table, OidSoFar, Oid, EntryME}
    end;

next_node({tree, Tree, _Info}, [Int | RestOfOid], RevOidSoFar, MibView) 
  when Int < size(Tree), Int >= 0 ->
    case next_node(element(Int+1,Tree),RestOfOid, [Int|RevOidSoFar], MibView) of
	false -> find_next({tree, Tree, _Info}, Int+1, RevOidSoFar, MibView);
	Else -> Else
    end;
%% no solution
next_node({tree, Tree, _Info}, [Int | RestOfOid], RevOidSoFar, MibView) ->
    false;
next_node({tree, Tree, _Info}, [], RevOidSoFar, MibView) ->
    find_next({tree, Tree, _Info}, 0, RevOidSoFar, MibView);

next_node({node,{subagent,SubAgentPid}}, Oid,
	  [SAInt | SARevOidSoFar], MibView) ->
    OidSoFar = lists:reverse([SAInt | SARevOidSoFar]),
    case snmp_acm:is_definitely_not_in_mib_view(OidSoFar, MibView) of
	true -> false;
	_ -> {subagent, SubAgentPid, OidSoFar}
    end;
    
next_node({node, {variable, {_MibName, VariableME}}}, [],
	  RevOidSoFar, MibView) ->
    OidSoFar = lists:reverse([0 | RevOidSoFar]),
    case snmp_acm:validate_mib_view(OidSoFar, MibView) of
	true -> {variable, VariableME, OidSoFar};
	_ -> false
    end;

next_node({node, {variable, _ME}}, _Oid, RevOidSoFar, MibView) ->
    false.

%%-----------------------------------------------------------------
%% This function is used to find the first leaf from where we
%% are.
%% Returns: {subagent, SubAgentPid, SAOid} |
%%          false |
%%          {variable, MibEntry, VarOid} |
%%          {table, TableOid, TableRestOid, MibEntry}
%% PRE: This function must always be called with a {internal, Tree}
%%      node.
%%-----------------------------------------------------------------
find_next({tree, Tree, internal}, Index, RevOidSoFar, MibView) 
  when Index < size(Tree) ->
    case find_next(element(Index+1, Tree), 0, [Index | RevOidSoFar], MibView) of
	false -> find_next({tree, Tree, internal},Index+1,RevOidSoFar, MibView);
	Other -> Other
    end;
find_next({tree, Tree, internal}, _Index, _RevOidSoFar, _MibView) ->
    false;
find_next(undefined_node, _Index, _RevOidSoFar, _MibView) ->
    false;
find_next({tree, Tree, {table, _Id}}, Index, RevOidSoFar, MibView) ->
    find_next({tree, Tree, internal}, Index, RevOidSoFar, MibView);
find_next({tree, Tree, {table_entry,{MibName,EntryME}}}, _Index,
	  RevOidSoFar, MibView) ->
    OidSoFar = lists:reverse(RevOidSoFar),
    case snmp_acm:is_definitely_not_in_mib_view(OidSoFar, MibView) of
	true -> false;
	_ -> {table, OidSoFar, [], EntryME}
    end;
find_next({node, {variable, {_MibName, VariableME}}}, _Index,
	  RevOidSoFar, MibView) ->
    OidSoFar = lists:reverse([0 | RevOidSoFar]),
    case snmp_acm:validate_mib_view(OidSoFar, MibView) of
	true -> {variable, VariableME, OidSoFar};
	_ -> false
    end;
find_next({node, {subagent, SubAgentPid}}, _Index, RevOidSoFar, MibView) ->
    OidSoFar = lists:reverse(RevOidSoFar),
    case snmp_acm:is_definitely_not_in_mib_view(OidSoFar, MibView) of
	true -> false;
	_ -> {subagent, SubAgentPid, OidSoFar}
    end.

%%%======================================================================
%%% 3. Tree building functions
%%%    Used when loading mibs.
%%%======================================================================

build_tree(Mes, MibName) ->
    {ListTree, []}  = build_subtree([], Mes, MibName),
    {tree, convert_tree(ListTree), internal}.

%%----------------------------------------------------------------------
%% Purpose: Builds the tree where all oids have prefix equal to LevelPrefix.
%% Returns: {Tree, RestMes}
%% RestMes are Mes that should not be in this subtree.
%% The Tree is a temporary and simplified data structure that is easy to
%% convert to the final tuple tree used by the MIB process.
%% A Node is represented as in the final tree.
%% The tree is not represented as a N-tuple, but as an Index-list.
%% Example: Temporary: [{1, Node1}, {3, Node3}]
%%          Final:     {Node1, undefined_node, Node3}
%% Pre: Mes are sorted on oid.
%% Comment: The assocList in #me is cleared to save some small amount of memory.
%%----------------------------------------------------------------------
build_subtree(LevelPrefix, [Me | Mes], MibName) ->
    ?debug("build subtree: ~n"
	   "   oid:         ~p~n"
	   "   LevelPrefix: ~p~n"
	   "   MibName:     ~p",[Me#me.oid,LevelPrefix,MibName]),
    EType = Me#me.entrytype,
    ?debug("build subtree: EType = ~p",[EType]),
    case in_subtree(LevelPrefix, Me) of
	above ->
	    ?debug("build subtree: above",[]),
	    {[], [Me|Mes]};
	{node, Index} ->
	    ?debug("build subtree: node at ~p",[Index]),
	    {Tree, RestMes} = build_subtree(LevelPrefix, Mes, MibName),
	    {[{Index, {node, {EType, {MibName, Me#me{assocList = undefined}}}}}
	      | Tree],
	     RestMes};
	{subtree, Index, NewLevelPrefix} ->
	    ?debug("build subtree: subtree at ~p with ~p",
		   [Index,NewLevelPrefix]),
	    {BelowTree, RestMes} = build_subtree(NewLevelPrefix, Mes, MibName),
	    {CurTree, RestMes2} = build_subtree(LevelPrefix, RestMes, MibName),
	    {[{Index, {tree, BelowTree,
		       {EType, {MibName, Me#me{assocList = undefined}}}}}
	      | CurTree],
	     RestMes2};
	{internal_subtree, Index, NewLevelPrefix} ->
	    ?debug("build subtree: internal_subtree at ~p with ~p",
		   [Index,NewLevelPrefix]),
	    {BelowTree, RestMes} =
		build_subtree(NewLevelPrefix, [Me | Mes], MibName),
	    {CurTree, RestMes2} =
		build_subtree(LevelPrefix, RestMes, MibName),
	    {[{Index, {tree, BelowTree, internal}} | CurTree], RestMes2}
    end;

build_subtree(_LevelPrefix, [], _MibName) -> {[], []}.

%%--------------------------------------------------
%% Purpose: Determine how/if/where Me should be inserted in subtree
%%          with LevelPrefix. This function does not build any tree, only 
%%          determinses what should be done (by build subtree).
%% Returns:
%% above - Indicating that this ME should _not_ be in this subtree.
%% {node, Index} - yes, construct a node with index Index on this level
%% {internal_subtree, Index, NewLevelPrefix} - yes, there should be an
%%   internal subtree at this index.
%% {subtree, Index, NewLevelPrefix} - yes, construct a subtree with 
%%   NewLevelPrefix and insert this on current level in position Index.
%%--------------------------------------------------
in_subtree(LevelPrefix, Me) ->
    case lists:prefix(LevelPrefix, Me#me.oid) of
	true when length(Me#me.oid) > length(LevelPrefix) ->
	    classify_how_in_subtree(LevelPrefix, Me);
	Else ->
	    above
    end.

%%--------------------------------------------------
%% See comment about in_subtree/2.  This function takes care of all cases
%% where the ME really should be in _this_ subtree (not above).
%%--------------------------------------------------
classify_how_in_subtree(LevelPrefix, Me) 
  when length(Me#me.oid) == length(LevelPrefix) + 1 ->
    Oid = Me#me.oid,
    case node_or_subtree(Me#me.entrytype) of
	subtree ->
	    {subtree, lists:last(Oid), Oid};
	node ->
	    {node, lists:last(Oid)}
    end;

classify_how_in_subtree(LevelPrefix, Me) 
  when length(Me#me.oid) > length(LevelPrefix) + 1 ->
    L1 = length(LevelPrefix) + 1,
    Oid = Me#me.oid,
    {internal_subtree, lists:nth(L1, Oid), lists:sublist(Oid, 1, L1)}.

%%--------------------------------------------------
%% Determines how to treat different kinds om MEs in the tree building process.
%% Pre: all internal nodes have been removed.
%%--------------------------------------------------
node_or_subtree(table) -> subtree;
node_or_subtree(table_entry) -> subtree;
node_or_subtree(variable) -> node;
node_or_subtree(table_column) -> node.

%%--------------------------------------------------
%% Purpose: (Recursively) Converts a temporary tree (see above) to a final tree.
%% If input is a ListTree, output is a TupleTree.
%% If input is a Node, output is the same Node.
%% Pre: All Indexes are >= 0.
%%--------------------------------------------------
convert_tree({Index, {tree, Tree, Info}}) when Index >= 0 ->
    L = lists:map(fun convert_tree/1, Tree),
    {Index, {tree, dict_list_to_tuple(L), Info}};
convert_tree({Index, {node, Info}}) when Index >= 0 ->
    {Index, {node, Info}};
convert_tree(Tree) when list(Tree) ->
    L = lists:map(fun convert_tree/1, Tree),
    dict_list_to_tuple(L).

%%----------------------------------------------------------------------
%% Purpose: Converts a single level (that is non-recursively) from
%%          the temporary indexlist to the N-tuple.
%% Input: A list of {Index, Data}.
%% Output: A tuple where element Index is Data.
%%----------------------------------------------------------------------
dict_list_to_tuple(L) ->
    L2 = lists:keysort(1, L),
    list_to_tuple(integrate_indexes(0, L2)).

%%----------------------------------------------------------------------
%% Purpose: Helper function for dict_list_to_tuple/1.
%%          Converts an indexlist to a N-list.
%% Input: A list of {Index, Data}.
%% Output: A (usually longer, never shorter) list where element Index is Data.
%% Example: [{1,hej}, {3, sven}] will give output 
%% [undefined_node, hej, undefined_node, sven].
%% Initially CurIndex should be 0.
%%----------------------------------------------------------------------
integrate_indexes(CurIndex, [{CurIndex, Data} | T]) ->
    [Data | integrate_indexes(CurIndex + 1, T)];
integrate_indexes(_Index, []) ->
    [];
integrate_indexes(CurIndex, L) ->
    [undefined_node | integrate_indexes(CurIndex + 1, L)].

%%%======================================================================
%%% 4. Tree merging
%%%    Used by: load mib, insert subagent.
%%%======================================================================

%%----------------------------------------------------------------------
%% Arg: Two root nodes (that is to be merged).
%% Returns: A new root node where the nodes have been merger to one.
%%----------------------------------------------------------------------
merge_nodes(Same, Same) -> 
    Same;
merge_nodes(Node, undefined_node) -> 
    Node;
merge_nodes(undefined_node, Node) -> 
    Node;
merge_nodes({tree, Tree1, internal}, {tree, Tree2, internal}) ->
    {tree, merge_levels(tuple_to_list(Tree1),tuple_to_list(Tree2)), internal};
merge_nodes(Node1, Node2) ->
    throw({error_merge_nodes, Node1, Node2}).

%%----------------------------------------------------------------------
%% Arg: Two levels to be merged.
%%      Here, a level is represented as a list of nodes. A list is easier
%%      to extend than a tuple.
%% Returns: The resulting, merged level tuple.
%%----------------------------------------------------------------------
merge_levels(Level1, Level2) when length(Level1) == length(Level2) ->
    list_to_tuple(snmp_misc:multi_map({snmp_mib_data, merge_nodes},
				      [Level1, Level2]));
merge_levels(Level1, Level2) when length(Level1) > length(Level2) ->
    merge_levels(Level1,Level2 ++ undefined_nodes_list(length(Level1)
						       - length(Level2)));
merge_levels(Level1, Level2) when length(Level1) < length(Level2) ->
    merge_levels(Level2, Level1).

undefined_nodes_list(0) -> [];
undefined_nodes_list(N) -> [undefined_node | undefined_nodes_list(N-1)].


%%%======================================================================
%%% 5. Tree deletion routines
%%%    (for unload mib)
%%%======================================================================

%%----------------------------------------------------------------------
%% Purpose:  Actually kicks of the tree reconstruction.
%% Returns: {list of removed MEs, NewTree}
%%----------------------------------------------------------------------
delete_mib_from_tree(MibName, {tree, Tree, internal}) ->
    case delete_tree(Tree, MibName) of
	{MEs, []} -> {MEs, {tree, {undefined_node}, internal}}; % reduce
	{MEs, LevelList} -> {MEs, {tree, list_to_tuple(LevelList), internal}}
    end.

%%----------------------------------------------------------------------
%% Purpose: Deletes all nodes associated to MibName from this level and
%%          all levels below.
%%          If the new level does not contain information (that is, no 
%%          other mibs use it) anymore the empty list is returned.
%% Returns: {MEs, The new level represented as a list}
%%----------------------------------------------------------------------
delete_tree(Tree, MibName) when tuple(Tree) ->
    {MEs, NewLevel} = delete_nodes(tuple_to_list(Tree), MibName, [], []),
    case lists:filter(fun drop_undefined_nodes/1,NewLevel) of
	[] -> {MEs, []};
	A_perhaps_shorted_list ->
	    {MEs, NewLevel}  % some other mib needs this level
    end.
    
%%----------------------------------------------------------------------
%% Purpose: Nodes belonging to MibName are removed from the tree.
%%          Recursively deletes sub trees to this node.
%% Returns: {MEs, NewNodesList}
%%----------------------------------------------------------------------
delete_nodes([], _MibName, AccNodes, AccMEs) ->
    {AccMEs, lists:reverse(AccNodes)};

delete_nodes([{node, {variable, {MibName, ME}}}|T],
	     MibName, AccNodes, AccMEs) ->
    delete_nodes(T, MibName, [undefined_node | AccNodes], [ME | AccMEs]);

delete_nodes([{node, {table_column, {MibName, ME}}}|T],
	    MibName, AccNodes, AccMEs) ->
    delete_nodes(T, MibName, [undefined_node | AccNodes], [ME | AccMEs]);

delete_nodes([{tree, Tree, {table, {MibName, ME}}}|T], 
	    MibName, AccNodes, AccMEs) ->
    {MEs, _Level} =
	delete_nodes(tuple_to_list(Tree),MibName,AccNodes,[ME | AccMEs]),
    delete_nodes(T, MibName, [undefined_node | AccNodes], MEs);

delete_nodes([{tree, Tree, {table_entry, {MibName, ME}}}|T], 
	    MibName, AccNodes, AccMEs) ->
    {MEs, _Level} =
	delete_nodes(tuple_to_list(Tree),MibName,AccNodes,[ME | AccMEs]),
    delete_nodes(T, MibName, [undefined_node | AccNodes], MEs);

delete_nodes([{tree, Tree, Info}|T], MibName, AccNodes, AccMEs) ->
    case delete_tree(Tree, MibName) of
	{MEs, []} -> % tree completely deleted
	    delete_nodes(T, MibName, [undefined_node | AccNodes],
			 lists:append(MEs,AccMEs));
	{MEs, LevelList} ->
	    delete_nodes(T, MibName, [{tree, list_to_tuple(LevelList), Info}
				      | AccNodes], lists:append(MEs,AccMEs))
    end;

delete_nodes([NodeToKeep|T], MibName, AccNodes, AccMEs) ->
    delete_nodes(T, MibName, [NodeToKeep | AccNodes], AccMEs).

drop_undefined_nodes(undefined_node) -> false;
drop_undefined_nodes(X) -> true.

%%%======================================================================
%%% 6. Functions for subagent handling
%%%======================================================================

%%----------------------------------------------------------------------
%% Returns: A new Root|{error, reason}
%%----------------------------------------------------------------------
insert_subagent(Oid, Pid, OldRoot) ->
    ListTree = build_tree_for_subagent(Oid, Pid),
    case catch convert_tree(ListTree) of
	{'EXIT', Reason} ->
	    {error, 'cannot construct tree from oid'};
	Level when tuple(Level) ->
	    T = {tree, Level, internal},
	    case catch merge_nodes(T, OldRoot) of
		{error_merge_nodes, Node1, Node2} ->
		    {error, oid_conflict};
		NewRoot when tuple(NewRoot), element(1, NewRoot)==tree->
		    NewRoot
	    end
    end.

build_tree_for_subagent([Index], Pid) ->
    [{Index, {node, {subagent, Pid}}}];

build_tree_for_subagent([Index | T], Pid) ->
    [{Index, {tree, build_tree_for_subagent(T, Pid), internal}}].

%%----------------------------------------------------------------------
%% Returns: A new tree where the subagent at Oid (2nd arg) has been deleted.
%%----------------------------------------------------------------------
delete_subagent({tree, Tree, Info}, [Index]) ->
    {node, {subagent, Pid}} = element(Index+1, Tree),
    {tree, setelement(Index+1, Tree, undefined_node), Info};
delete_subagent({tree, Tree, Info}, [Index | TI]) ->
    {tree, setelement(Index+1, Tree,
		      delete_subagent(element(Index+1, Tree), TI)), Info}.

%%%======================================================================
%%% 7. Misc functions
%%%======================================================================

%%----------------------------------------------------------------------
%% Does all side effect stuff during load_mib.
%%----------------------------------------------------------------------
install_mib(Symbolic, Mib, MibName, FileName, MibsEts, NonInternalMes) ->
    ?vdebug("install mib with ~n"
	    "\tSymbolic: ~p~n"
	    "\tMibName:  ~p~n"
	    "\tFileName: ~p",
	    [Symbolic,MibName,FileName]),
    ets:insert(MibsEts, {MibName, Symbolic, FileName}),
    MEs = Mib#mib.mes,
    case Symbolic of
	true ->
	    snmp_symbolic_store:add_table_infos(MibName, Mib#mib.table_infos),
	    snmp_symbolic_store:add_variable_infos(MibName,
						   Mib#mib.variable_infos),
	    snmp_symbolic_store:add_aliasnames(MibName, MEs),
	    snmp_symbolic_store:add_types(MibName,Mib#mib.asn1_types),
	    snmp_misc:foreach({snmp_symbolic_store,set_notification},[MibName],
			      Mib#mib.traps);
	false ->
	    ok
    end,
    snmp_misc:foreach({snmp_mib_data, call_instrumentation},
		      [new], NonInternalMes).

%%----------------------------------------------------------------------
%% Does all side effect stuff during unload_mib.
%%----------------------------------------------------------------------
uninstall_mib(Symbolic, MibName, MibsEts, MEs) ->
    ets:delete(MibsEts, MibName),
    case Symbolic of
	true ->
	    snmp_symbolic_store:delete_table_infos(MibName),
	    snmp_symbolic_store:delete_variable_infos(MibName),
	    snmp_symbolic_store:delete_aliasnames(MibName),
	    snmp_symbolic_store:delete_types(MibName),
	    snmp_symbolic_store:delete_notifications(MibName);
	false ->
	    ok
    end,
    snmp_misc:foreach({snmp_mib_data, call_instrumentation}, [delete], MEs).

%%----------------------------------------------------------------------
%% Calls MFA-instrumentation with 'new' or 'delete' operation.
%%----------------------------------------------------------------------
call_instrumentation(#me{entrytype = variable, mfa={M,F,A}}, Operation) ->
    ?vtrace("call instrumentation with~n"
	    "~n   entrytype: variable"
	    "~n   MFA:       {~p,~p,~p}"
	    "~n   Operation: ~p",
	    [M,F,A,Operation]),
    catch apply(M, F, [Operation | A]);
call_instrumentation(#me{entrytype = table_entry, mfa={M,F,A}}, Operation) ->
    ?vtrace("call instrumentation with"
	    "~n   entrytype: table_entry"
	    "~n   MFA:       {~p,~p,~p}"
	    "~n   Operation: ~p",
	    [M,F,A,Operation]),
    catch apply(M, F, [Operation | A]);
call_instrumentation(ShitME, Operation) ->
    done.

drop_internal_and_imported(#me{entrytype = internal}) -> false;
drop_internal_and_imported(#me{imported = true}) -> false;
drop_internal_and_imported(X) -> true.


%%----------------------------------------------------------------------
%% Code change functions
%%----------------------------------------------------------------------

code_change({up,Vsn},State) ->
    ?debug("upgrade from ~p",[Vsn]),
    ?store("mibs_data-up_original.bin",State#snmp_mib_data.tree),
    NTree = tree_upgrade(State#snmp_mib_data.tree),
    ?debug("upgrade complete",[]),
    ?store("mibs_data-up_new.bin",NTree),
    State#snmp_mib_data{tree = NTree};

code_change({down,Vsn},State) ->
    ?debug("downgrade to ~p",[Vsn]),
    ?store("mibs_data-down_original.bin",State#snmp_mib_data.tree),
    NTree = tree_downgrade(State#snmp_mib_data.tree),
    ?debug("downgrade complete",[]),
    ?store("mibs_data-down_new.bin",NTree),
    State#snmp_mib_data{tree = NTree}.


-ifdef(snmp_debug).
store(Name,Tree) ->
    store(file:write_file(Name,term_to_binary(Tree))).

store(ok) -> 
    ok;
store({error,Reason}) ->
    ?debug("failed storing: ~p",[Reason]).
-endif.


%% Upgrade a tree, i.e. upgrade all me-records
tree_upgrade(Tree) ->
    ?debug("upgrade tree",[]),
    tree_code_change(Tree,up).

%% Downgrade a tree, i.e. downgrade all me-records
tree_downgrade(Tree) ->
    ?debug("downgrade tree",[]),
    tree_code_change(Tree,down).

tree_code_change({tree,Tree,Info},How) ->
    ?debug("tree: ~pgrade tree",[How]),
    {tree,tree_code_change(Tree,How),tree_info_code_change(Info,How)};
tree_code_change({node,Info},How) ->
    ?debug("tree: ~pgrade node",[How]),
    {node_info_code_change(Info,How)};
tree_code_change(undefined_node,_How) -> 
    ?debug("tree: ignoring ~p",[undefined_node]),
    undefined_node;
tree_code_change(T,How) when tuple(T) -> 
    ?debug("tree: ~pgrade ~p-tuple",[How,size(T)]),
    tree_code_change1(1,T,How);
tree_code_change(Any,_How) -> 
    ?debug("tree: ignoring ~p",[Any]),
    Any.

tree_code_change1(N,T,How) when N =< size(T) -> 
    ?debug("tree-~p: ~pgrade ~p-tuple",[N,How,size(T)]),
    E = tree_code_change(element(N,T),How),
    tree_code_change1(N+1,setelement(N,T,E),How);
tree_code_change1(_N,T,How) ->
    ?debug("tree-n: ~pgrade of ~p-tuple done",[How,size(T)]),
    T.

tree_info_code_change({table,Id},How) ->
    ?debug("tree info: ~pgrade table",[How]),
    {table,id_code_change(Id,How)};
tree_info_code_change({table_entry,Id},How) ->
    ?debug("tree info: ~pgrade table_entry",[How]),
    {table_entry,id_code_change(Id,How)};
tree_info_code_change(Any,_How) ->
    ?debug("tree info: ignoring ~p",[Any]),
    Any.

node_info_code_change({variable,Id},How) ->
    ?debug("node info: ~pgrade variable",[How]),
    {variable,id_code_change(Id,How)};
node_info_code_change({table_column,Id},How) ->
    ?debug("node info: ~pgrade table_column",[How]),
    {table_colum,id_code_change(Id,How)};
node_info_code_change(Any,_How) ->
    ?debug("node info: ignoring ~p",[Any]),
    Any.

id_code_change({MibName,MibEntry},up) ->
    {MibName,me_upgrade(MibEntry)};
id_code_change({MibName,MibEntry},down) ->
    {MibName,me_downgrade(MibEntry)}.


%% Convert old me record to new me record (description gets the default value).
me_upgrade({me,Oid,EntryType,AliasName,Asn1Type,Access,MFA,Imported,Assoc}) -> 
    ?debug("upgrade me-record with oid = ~p",[Oid]),
    #me{oid       = Oid, 
	entrytype = EntryType,
	aliasname = AliasName,
	asn1_type = Asn1Type,
	access    = Access,
	mfa       = MFA,
	imported  = Imported,
	assocList = Assoc};
me_upgrade(Any) -> Any.

%% Convert new me record to old me record (description gets dropped).
me_downgrade(Me) when record(Me,me) ->
    #me{oid       = Oid, 
	entrytype = EntryType,
	aliasname = AliasName,
	asn1_type = Asn1Type,
	access    = Access,
	mfa       = MFA,
	imported  = Imported,
	assocList = Assoc} = Me,
    ?debug("downgrade me-record with oid = ~p",[Oid]),
    {me,Oid,EntryType,AliasName,Asn1Type,Access,MFA,Imported,Assoc};
me_downgrade(Any) -> Any.

