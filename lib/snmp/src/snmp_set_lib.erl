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
-module(snmp_set_lib).

-include("snmp_types.hrl").

-define(VMODULE,"SETLIB").
-include("snmp_verbosity.hrl").


%% External exports
-export([is_varbinds_ok/1, consistency_check/1,
	 undo_varbinds/1, try_set/1]).

%%%-----------------------------------------------------------------
%%% This module implements functions common to all different set
%%% mechanisms. 
%%%-----------------------------------------------------------------
%% Phase 1 of the set-operation. (see rfc1905:4.2.5)
%% Input is a sorted Varbinds list.
%% Output is either ok or {ErrIndex, ErrCode}.
%%*  1) IF the variable is outside the mib view THEN noAccess.
%%*  2a) IF the varaible doesn't exist THEN notWritable.
%%   2b) IF mib isn't able to create instances of the variable (for 
%%       example in a table) THEN noCreation.
%%*  3) IF the new value provided is of the wrong ASN.1 type THEN wrongType.
%%*  4) IF then new value is of wrong length THEN wrongLength.
%%#  5) IF value is incorrectly encoded THEN wrongEncoding. [nyi]
%%*  6) IF value is outside the acceptable range THEN wrongValue.
%%   7) IF variable does not exist and could not ever be created
%%      THEN noCreation.
%%   8) IF variable can not be created now THEN inconsistentName.
%%   9) IF value can not be set now THEN inconsistentValue.
%%*  9) IF instances of the variable can not be modified THEN notWritable.
%%  10) IF an unavailable resource is needed THEN resourceUnavailable.
%%  11) IF any other error THEN genErr.
%%  12) Otherwise ok!
%% The Agent takes care of *-marked. (# should be done by the agent but is
%% nyi.)
%% The rest is taken care of in consistency_check that communicates with the mib
%% (through the is_set_ok-function (for each variable)).
%%
%% SNMPv1  (see rfc1157:4.1.5)
%%*  1) IF variable not available for set in the mibview THEN noSuchName.
%%*  2) IF variable exists, but doesn't permit writeing THEN readOnly.
%%*  3) IF provided value doesn't match ASN.1 type THEN badValue.
%%   4) IF any other error THEN genErr.
%%   5) Otherwise ok!
%%
%% Internally we use snmpv2 messages, and convert them to the appropriate
%% v1 msg.
%%-----------------------------------------------------------------
%% Func: is_varbinds_ok/2
%% Purpose: Call is_varbind_ok for each varbind
%% Returns: {noError, 0} | {ErrorStatus, ErrorIndex}
%%-----------------------------------------------------------------
is_varbinds_ok([{_TableOid, TableVbs} | IVarbinds]) -> 
    is_varbinds_ok(lists:append(TableVbs, IVarbinds));
is_varbinds_ok([IVarbind | IVarbinds]) -> 
    case catch is_varbind_ok(IVarbind) of
	true -> is_varbinds_ok(IVarbinds);
	ErrorStatus -> 
	    Varbind = IVarbind#ivarbind.varbind,
	    ?vtrace("varbinds erroneous: ~p -> ~p",
		    [Varbind#varbind.org_index,ErrorStatus]),
	    {ErrorStatus, Varbind#varbind.org_index}
    end;
is_varbinds_ok([]) -> 
    ?vtrace("varbinds ok",[]),
    {noError, 0}.

%%-----------------------------------------------------------------
%% Func: is_varbind_ok/1
%% Purpose: Check everything we can check about the varbind against
%%          the MIB. Here we don't call any instrumentation functions.
%% Returns: true |
%% Fails:   with an <error-atom>.
%%-----------------------------------------------------------------
is_varbind_ok(#ivarbind{status = Status, 
			mibentry = MibEntry,
			varbind = Varbind}) ->
    variableExists(Status, MibEntry, Varbind),
    % If we get here, MibEntry /= false
    variableIsWritable(MibEntry, Varbind),
    checkASN1Type(MibEntry, Varbind),
    checkValEncoding(MibEntry, Varbind),
    true.

variableExists(noError, false, Varbind) -> throw(notWritable);
variableExists(noError, MibEntry, Varbind) -> true;
%% ErrorStatus == noSuchObject | noSuchInstance
variableExists(noSuchObject, MibEntry, Varbind) -> throw(notWritable);
variableExists(ErrorStatus, MibEntry, Varbind) -> throw(noCreation).

variableIsWritable(#me{access = 'read-write'}, Varbind) -> true;
variableIsWritable(#me{access = 'read-create'}, Varbind) -> true;
variableIsWritable(#me{access = 'write-only'}, Varbind) -> true;
variableIsWritable(MibEntry, Varbind) -> throw(notWritable).

%% Uses make_value_a_correct_value to check type, length and range.
%% Returns: true | <error-atom>
checkASN1Type(#me{asn1_type = ASN1Type},
	      #varbind{variabletype = Type, value = Value}) 
     when ASN1Type#asn1_type.bertype == Type ->
    case make_value_a_correct_value({value, Value}, ASN1Type,
				    undef) of
	{value, Type, Value} -> true;
	{error, Error} when atom(Error) -> throw(Error)
    end;

checkASN1Type(_,_) -> throw(wrongType).


%% tricky...
checkValEncoding(MibEntry, Varbind) -> true.

%%-----------------------------------------------------------------
%% Func: consistency_check/1
%% Purpose: Scans all vbs, and checks whether there is a is_set_ok
%%          function or not. If it exists, it is called with the
%%          vb, to check if the set-op is ok. If it doesn't exist,
%%          it is considered ok to set the variable.
%% Returns: {noError, 0} | {ErrorStatus, ErrorIndex]
%% PRE: #ivarbind.status == noError for each varbind
%%-----------------------------------------------------------------
consistency_check(Varbinds) ->
    consistency_check(Varbinds, []).
consistency_check([{TableOid, TableVbs} | Varbinds], Done) ->
    ?vtrace("consistency check:"
	    "~n   ~p -> ~p",[TableOid,TableVbs]),
    TableOpsWithShortOids = deletePrefixes(TableOid, TableVbs),
    [#ivarbind{mibentry = MibEntry}|_] = TableVbs,
    case is_set_ok_table(MibEntry, TableOpsWithShortOids) of
	{noError, 0} ->
	    consistency_check(Varbinds, [{TableOid, TableVbs} | Done]);
	{Reason, Idx} ->
	    case undo_varbinds(Done) of
		{noError, 0} -> {Reason, find_org_index(Idx, TableVbs)};
		Error -> Error
	    end
    end;
consistency_check([IVarbind | Varbinds], Done) ->
    ?vtrace("consistency check: ~p",[IVarbind]),
    #ivarbind{varbind = Varbind, mibentry = MibEntry} = IVarbind,
    #varbind{oid = Oid, value = Value, org_index = OrgIndex} = Varbind,
    case is_set_ok_variable(MibEntry, Value) of
	noError -> consistency_check(Varbinds, [IVarbind | Done]);
	Reason ->
	    case undo_varbinds(Done) of
		{noError, 0} -> {Reason, OrgIndex};
		Error -> Error
	    end
    end;
consistency_check([], _Done) -> 
    ?vtrace("consistency check: done",[]),
    {noError, 0}.

deletePrefixes(Prefix, [#ivarbind{varbind = Varbind} | Vbs]) ->
    #varbind{oid = Oid, value = Value} = Varbind,
    [{snmp_misc:diff(Oid, Prefix), Value} | deletePrefixes(Prefix, Vbs)];
deletePrefixes(Prefix, []) -> [].

%% Val = <a-value>
is_set_ok_variable(#me{mfa = {Module, Func, Args}}, Val) ->
    ?vtrace("is variable set ok: ~p, ~p",[{Module,Func,Args},Val]),
    case dbg_apply(Module, Func, [is_set_ok, Val | Args]) of
	{'EXIT', {hook_undef, _}} -> noError;
	{'EXIT', {hook_function_clause, _}} -> noError;
	Result -> validate_err(is_set_ok, Result, {Module, Func, Args})
    end.
    
%% ValueArg: <list-of-simple-tableops>
is_set_ok_table(#me{mfa = {Module, Func, Args}}, ValueArg) ->
    ?vtrace("is table set ok: ~p, ~p",[{Module,Func,Args},ValueArg]),
    is_set_ok_all_rows(Module, Func, Args, sort_varbinds_rows(ValueArg), []).

%% Try one row at a time. Sort varbinds to table-format.
is_set_ok_all_rows(Module, Func, Args, [Row | Rows], Done) ->
    ?vtrace("is all-rows set ok: ~p, ~p, ~p",[{Module,Func,Args},Row,Done]),
    [{RowIndex, Cols}] = delete_org_index([Row]),
    case dbg_apply(Module, Func, [is_set_ok, RowIndex, Cols | Args]) of
	{'EXIT', {hook_undef, _}} ->
	    is_set_ok_all_rows(Module, Func, Args, Rows, [Row | Done]);
	{'EXIT', {hook_function_clause, _}} -> 
	    is_set_ok_all_rows(Module, Func, Args, Rows, [Row | Done]);
	Result -> 
	    case validate_err(table_is_set_ok, Result, {Module, Func, Args}) of
		{noError, 0} -> 
		    is_set_ok_all_rows(Module, Func, Args, Rows, [Row | Done]);
		{ErrorStatus, ColNumber} ->
		    case undo_all_rows(Module, Func, Args, Done) of
			{noError, 0} -> 
			    {RowIndex, OrgCols} = Row,
			    validate_err(row_is_set_ok,
					 {ErrorStatus, 
					  col_to_orgindex(ColNumber,OrgCols)},
					 {Module, Func, Args});
			Error -> Error
		    end
	    end
    end;
is_set_ok_all_rows(_Module, _Func, _Args, [], _Done) -> 
    ?vtrace("is all-rows set ok: done",[]),
    {noError, 0}.

undo_varbinds([{TableOid, TableVbs} | Varbinds]) ->
    TableOpsWithShortOids = deletePrefixes(TableOid, TableVbs),
    [#ivarbind{mibentry = MibEntry}|_] = TableVbs,
    case undo_table(MibEntry, TableOpsWithShortOids) of
	{noError, 0} ->
	    undo_varbinds(Varbinds);
	{Reason, Idx} ->
	    undo_varbinds(Varbinds),
	    {Reason, Idx}
    end;
undo_varbinds([IVarbind | Varbinds]) ->
    #ivarbind{varbind = Varbind, mibentry = MibEntry} = IVarbind,
    #varbind{oid = Oid, value = Value, org_index = OrgIndex} = Varbind,
    case undo_variable(MibEntry, Value) of
	noError -> undo_varbinds(Varbinds);
	Reason ->
	    undo_varbinds(Varbinds),
	    {Reason, OrgIndex}
    end;
undo_varbinds([]) -> {noError, 0}.

%% Val = <a-value>
undo_variable(#me{mfa = {Module, Func, Args}}, Val) ->
    case dbg_apply(Module, Func, [undo, Val | Args]) of
	{'EXIT', {hook_undef, _}} -> noError;
	{'EXIT', {hook_function_clause, _}} -> noError;
	Result -> validate_err(undo, Result, {Module, Func, Args})
    end.
    
%% ValueArg: <list-of-simple-tableops>
undo_table(#me{mfa = {Module, Func, Args}}, ValueArg) ->
    undo_all_rows(Module, Func, Args, sort_varbinds_rows(ValueArg)).

undo_all_rows(Module, Func, Args, [Row | Rows]) ->
    [{RowIndex, Cols}] = delete_org_index([Row]),
    case dbg_apply(Module, Func, [undo, RowIndex, Cols | Args]) of
	{'EXIT', {hook_undef, _}} ->
	    undo_all_rows(Module, Func, Args, Rows);
	{'EXIT', {hook_function_clause, _}} -> 
	    undo_all_rows(Module, Func, Args, Rows);
	Result -> 
	    case validate_err(table_undo, Result, {Module, Func, Args}) of
		{noError, 0} -> undo_all_rows(Module, Func, Args, Rows);
		{ErrorStatus, ColNumber} ->
		    {RowIndex, OrgCols} = Row,
		    undo_all_rows(Module, Func, Args, Rows),
		    OrgIdx = col_to_orgindex(ColNumber, OrgCols),
		    validate_err(row_undo, {ErrorStatus, OrgIdx},
				 {Module, Func, Args})
	    end
    end;
undo_all_rows(_Module, _Func, _Args, []) ->
    {noError, 0}.
    
try_set([{TableOid, TableVbs} | Varbinds]) ->
    TableOpsWithShortOids = deletePrefixes(TableOid, TableVbs),
    [#ivarbind{mibentry = MibEntry}|_] = TableVbs,
    case set_value_to_tab_mibentry(MibEntry, TableOpsWithShortOids) of
	{noError, 0} -> 
	    try_set(Varbinds);
	{ErrorStatus, Index} ->
	    undo_varbinds(Varbinds),
	    {ErrorStatus, find_org_index(Index, TableVbs)}
    end;
try_set([#ivarbind{varbind = Varbind, mibentry = MibEntry} | Varbinds]) ->
    #varbind{value = Value, org_index = Index} = Varbind,
    case set_value_to_var_mibentry(MibEntry, Value) of
	noError -> try_set(Varbinds);
	Error ->
	    undo_varbinds(Varbinds),
	    {Error, Index}
    end;
try_set([]) -> {noError, 0}.


%% returns: ErrMsg 
set_value_to_var_mibentry(#me{mfa = {Module, Func, Args}},
			  SetArgs) ->
    Result = dbg_apply(Module, Func, [set, SetArgs | Args]),
    validate_err(set, Result, {Module, Func, Args}).

%% returns: {ErrMsg, Idx}
set_value_to_tab_mibentry(#me{mfa = {Module, Func, Args}},
			  SetArgs) ->
    set_value_all_rows(Module, Func, Args, 
		       sort_varbinds_rows(SetArgs)).


set_value_all_rows(Module, Func, Args, []) -> {noError, 0};
set_value_all_rows(Module, Func, Args, [Row | Rows]) ->
    [{RowIndex, Cols}] = delete_org_index([Row]),
    Res = dbg_apply(Module, Func, [set, RowIndex, Cols | Args]),
    case validate_err(table_set, Res, {Module, Func, Args}) of
	{noError, 0} -> set_value_all_rows(Module, Func, Args, Rows);
	{ErrCode, ColNumber} ->
	    {RowIndex, OrgCols} = Row,
	    OrgIndex = col_to_orgindex(ColNumber, OrgCols),
	    validate_err(row_set, {ErrCode, OrgIndex}, {Module, Func, Args})
    end.

sort_varbinds_rows(Varbinds) ->
    snmp_svbl:sort_varbinds_rows(Varbinds).
delete_org_index(Indexes) ->
    snmp_svbl:delete_org_index(Indexes).
col_to_orgindex(ColNumber, OrgCols) ->
    snmp_svbl:col_to_orgindex(ColNumber, OrgCols).

find_org_index(ExternIndex, SortedVarbinds) when ExternIndex == 0 -> 0;
find_org_index(ExternIndex, SortedVarbinds) ->
    VBs = lists:flatten(SortedVarbinds),
    case length(VBs) of
	Len when ExternIndex =< Len, ExternIndex >= 1 ->
	    IVB = lists:nth(ExternIndex, VBs),
	    VB = IVB#ivarbind.varbind,
	    VB#varbind.org_index;
	Else ->
	    0
    end.

validate_err(Type, Error, Mfa) ->
    snmp_agent:validate_err(Type, Error, Mfa).
make_value_a_correct_value(Value, ASN1Type, Mfa) ->
    snmp_agent:make_value_a_correct_value(Value, ASN1Type, Mfa).

%%-----------------------------------------------------------------
%% Runtime debug support
%%-----------------------------------------------------------------

% XXX: This function match on the exakt return codes from EXIT
% messages. As of this writing it was not decided if this is
% the right way so don't blindly do things this way.
%
% We fake a real EXIT signal as the return value because the
% result is passed to the function snmp_agent:validate_err()
% that expect it.
  
dbg_apply(M,F,A) ->
    Result =
	case get(verbosity) of
	    false ->
		(catch apply(M,F,A));
	    _ ->
		?vlog("~n   apply: ~w,~w,~p~n", [M,F,A]),
		Res = (catch apply(M,F,A)),
		?vlog("~n   returned: ~p", [Res]),
		Res
	end,
    case Result of
	{'EXIT', {undef, [{M, F, A} | _]}} ->
	    {'EXIT', {hook_undef, {M, F, A}}};
	{'EXIT', {function_clause, [{M, F, A} | _]}} ->
	    {'EXIT', {hook_function_clause, {M, F, A}}};

	% XXX: Old format for compatibility
	{'EXIT', {undef, {M, F, A}}} ->
	    {'EXIT', {hook_undef, {M, F, A}}};
	{'EXIT', {function_clause, {M, F, A}}} ->
	    {'EXIT', {hook_function_clause, {M, F, A}}};

	Result ->
	    Result
    end.

