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
-module(snmp_acm).

-export([init_check_access/2, get_root_mib_view/0,
	 error2status/1,
	 validate_mib_view/2, validate_all_mib_view/2,
	 is_definitely_not_in_mib_view/2]).

-include("snmp_types.hrl").
-include("STANDARD-MIB.hrl").
-include("SNMP-FRAMEWORK-MIB.hrl").
-include("SNMPv2-TM.hrl").

-define(VMODULE,"ACM").
-include("snmp_verbosity.hrl").


%%%-----------------------------------------------------------------
%%% This module implements the Access Control Model part of the
%%% multi-lingual SNMP agent.  It contains generic function not
%%% tied to a specific model, but in this version it uses VACM.
%%%
%%% Note that we don't follow the isAccessAllowed Abstract Service
%%% Interface defined in rfc2271.  We implement an optimization
%%% of that ASI.  Since the mib view is the same for all variable
%%% bindings in a PDU, there is no need to recalculate the mib
%%% view for each variable.  Therefore, one function
%%% (init_check_access/2) is used to find the mib view, and then
%%% each variable is checked against this mib view.
%%%
%%% Access checking is done in several steps.  First, the version-
%%% specific MPD (see snmp_mpd) creates data used by VACM.  This
%%% means that the format of this data is known by both the MPD and
%%% the ACM.  When the master agent wants to check the access to a
%%% Pdu, it first calls init_check_access/2, which returns a MibView
%%% that can be used to check access of individual variables.
%%%-----------------------------------------------------------------

%%-----------------------------------------------------------------
%% Func: init_check_access(Pdu, ACMData) ->
%%       {ok, MibView, ContextName} |
%%       {error, Reason} |
%%       {discarded, Variable, Reason}
%% Types: Pdu = #pdu
%%        ACMData = acm_data() = {community, Community, Address} |
%%                               {v3, MsgID, SecModel, SecName, SecLevel,
%%                                    ContextEngineID, ContextName, SecData}
%%        Community       = string()
%%        Address         = ip() ++ udp() (list)
%%        MsgID           = integer() <not used>
%%        SecModel        = ?SEC_*  (see snmp_types.hrl)
%%        SecName         = string()
%%        SecLevel        = ?'SnmpSecurityLevel_*' (see SNMP-FRAMEWORK-MIB.hrl)
%%        ContextEngineID = string() <not used>
%%        ContextName     = string()
%%        SecData         = <not used>
%%        Variable        = snmpInBadCommunityNames |
%%                          snmpInBadCommunityUses |
%%                          snmpInASNParseErrs
%%        Reason          = snmp_message_decoding |
%%                          {bad_community_name, Address, Community}} |
%%                          {invalid_access, Access, Op}
%% 
%% Purpose: Called once for each Pdu.  Returns a MibView
%%          which is later used for each variable in the pdu.
%%          The authenticationFailure trap is sent (maybe) when the auth.
%%          procedure evaluates to unauthentic,
%%
%% NOTE: This function is executed in the Master agents's context
%%-----------------------------------------------------------------
init_check_access(Pdu, ACMData) ->
    case init_ca(Pdu, ACMData) of
	{ok, MibView, ContextName} ->
	    {ok, MibView, ContextName};
	{discarded, Reason} ->
	    {error, Reason};
	{authentication_failure, Variable, Reason} ->
	    handle_authentication_failure(),
	    {discarded, Variable, Reason}
    end.

error2status(noSuchView) -> authorizationError;
error2status(noAccessEntry) -> authorizationError;
error2status(noGroupName) -> authorizationError;
error2status(_) -> genErr.
     
%%-----------------------------------------------------------------
%% Func: init_ca(Pdu, ACMData) ->
%%       {ok, MibView} |
%%       {discarded, Reason} |
%%       {authentication_failure, Variable, Reason}
%%
%% error: an error response will be sent
%% discarded: no error response is sent
%% authentication_failure: no error response is sent, a trap is generated
%%-----------------------------------------------------------------
init_ca(Pdu, {community, SecModel, Community, TAddr}) ->
    %% This is a v1 or v2c request.   Use SNMP-COMMUNITY-MIB to
    %% map the community to vacm parameters.
    ?vtrace("check access for ~n"
	    "   Pdu:            ~p~n"
	    "   Security model: ~p~n"
	    "   Community:      ~s",[Pdu,SecModel,Community]),
    ViewType = case Pdu#pdu.type of
		   'set-request' -> write;
		   _ -> read
	       end,
    ?vtrace("View type: ~p",[ViewType]),
    case snmp_community_mib:community2vacm(Community, {?snmpUDPDomain,TAddr}) of
	{SecName, _ContextEngineId, ContextName} ->
	    %% Maybe we should check that the contextEngineID matches the
	    %% local engineID?  It better, since we don't impl. proxy.
	    ?vtrace("get mib view"
		    "~n   Security name: ~p"
		    "~n   Context name:  ~p",[SecName,ContextName]),
	    case snmp_vacm:get_mib_view(ViewType, SecModel, SecName,
					?'SnmpSecurityLevel_noAuthNoPriv',
					ContextName) of
		{ok, MibView} ->
		    put(sec_model, SecModel),
		    put(sec_name, SecName),
		    {ok, MibView, ContextName};
		{discarded, Reason} ->
		    snmp_mpd:inc(snmpInBadCommunityUses),
		    {discarded, Reason}
	    end;
	undefined ->
	    {authentication_failure, snmpInBadCommunityNames,
	     {bad_community_name, TAddr, Community}}
    end;
init_ca(Pdu, {v3, _MsgID, SecModel, SecName, SecLevel,
	      _ContextEngineID, ContextName, _SecData}) ->
    ?vtrace("check v3 access for ~n"
	    "   Pdu:            ~p~n"
	    "   Security model: ~p~n"
	    "   Security name:  ~p~n"
	    "   Security level: ~p",[Pdu,SecModel,SecName,SecLevel]),
    ViewType = case Pdu#pdu.type of
		   'set-request' -> write;
		   _ -> read
	       end,
    ?vtrace("View type: ~p",[ViewType]),
    %% Convert the msgflag value to a ?'SnmpSecurityLevel*'
    SL = case SecLevel of
	     0 -> ?'SnmpSecurityLevel_noAuthNoPriv';
	     1 -> ?'SnmpSecurityLevel_authNoPriv';
	     3 -> ?'SnmpSecurityLevel_authPriv'
	 end,
    put(sec_model, SecModel),
    put(sec_name, SecName),
    case snmp_vacm:get_mib_view(ViewType, SecModel, SecName, SL, ContextName) of
	{ok, MibView} ->
	    {ok, MibView, ContextName};
	Else ->
	    Else
    end.

%%-----------------------------------------------------------------
%% Func: check(Res) -> {ok, MibView} | {discarded, Variable, Reason}
%% Args: Res = {ok, AccessFunc} | {authentication_failure, Variable, Reason
%%-----------------------------------------------------------------

%%-----------------------------------------------------------------
%% NOTE: This function is executed in the Master agents's context
%% Do a GET to retrieve the value for snmpEnableAuthenTraps.  A
%% user may have another impl. than default for this variable.
%%-----------------------------------------------------------------
handle_authentication_failure() ->
    case snmp_agent:do_get(get_root_mib_view(),
			   [#varbind{oid = ?snmpEnableAuthenTraps_instance}],
			   true) of
	{noError, _, [#varbind{value = ?snmpEnableAuthenTraps_enabled}]} ->
	    snmp:send_notification(self(), authenticationFailure, no_receiver);
	_ ->
	    ok
    end.

%%%-----------------------------------------------------------------
%%% MIB View handling
%%%-----------------------------------------------------------------

get_root_mib_view() ->
    [{[1], [], ?view_included}].

%%-----------------------------------------------------------------
%% Returns true if Oid is in the MibView, false
%% otherwise.
%% Alg: (defined in SNMP-VIEW-BASED-ACM-MIB)
%% For each family (= {SubTree, Mask, Type}), check if Oid
%% belongs to that family. For each family that Oid belong to,
%% get the longest. If two or more are longest, get the
%% lexicografically greatest. Check the type of this family. If
%% included, then Oid belongs to the MibView, otherwise it
%% does not.
%% Optimisation: Do only one loop, and kepp the largest sofar.
%% When we find a family that Oid belongs to, check if it is
%% larger than the largest.
%%-----------------------------------------------------------------
validate_mib_view(Oid, MibView) ->
    case get_largest_family(MibView, Oid, undefined) of
	{_, _, ?view_included} -> true;
	_ -> false
    end.

get_largest_family([{SubTree, Mask, Type} | T], Oid, Res) ->
    case check_mask(Oid, SubTree, Mask) of
	true -> get_largest_family(T, Oid, add_res(length(SubTree), SubTree,
						   Type, Res));
	false -> get_largest_family(T, Oid, Res)
    end;
get_largest_family([], Oid, Res) -> Res.

%%-----------------------------------------------------------------
%% We keep only the largest (first longest SubTree, and then 
%% lexicografically greatest) SubTree.
%%-----------------------------------------------------------------
add_res(Len, SubTree, Type, undefined) ->
    {Len, SubTree, Type};
add_res(Len, SubTree, Type, {MaxLen, MaxS, MaxT}) when Len > MaxLen ->
    {Len, SubTree, Type};
add_res(Len, SubTree, Type, {MaxLen, MaxS, MaxT}) when Len == MaxLen ->
    if
	SubTree > MaxS -> {Len, SubTree, Type};
	true -> {MaxLen, MaxS, MaxT}
    end;
add_res(_Len, _SubTree, _Type, MaxRes) -> MaxRes.


%% 1 in mask is exact match, 0 is wildcard.
%% If mask is shorter than SubTree, its regarded
%% as being all ones.
check_mask(Oid, [], Mask) -> true;
check_mask([X | Xs], [X | Ys], [1 | Ms]) ->
    check_mask(Xs, Ys, Ms);
check_mask([X | Xs], [X | Ys], []) ->
    check_mask(Xs, Ys, []);
check_mask([X | Xs], [Y | Ys], [0 | Ms]) ->
    check_mask(Xs, Ys, Ms);
check_mask(_, _, _) -> false.

%%-----------------------------------------------------------------
%% Validates all oids in the Varbinds list towards the MibView.
%%-----------------------------------------------------------------
validate_all_mib_view([#varbind{oid = Oid, org_index = Index} | Varbinds],
		      MibView) ->
    case validate_mib_view(Oid, MibView) of
	true -> validate_all_mib_view(Varbinds, MibView);
	false -> {false, Index}
    end;
validate_all_mib_view([], MibView) ->
    true.

%%-----------------------------------------------------------------
%% This function is used to optimize the next operation in
%% snmp_mib_data. If we get to a node in the tree where we can
%% determine that we are guaranteed to be outside the mibview,
%% we don't have to continue the search in the that tree (Actually
%% we will, because we only check this at leafs. But we won't
%% go into tables or subagents, and that's the important
%% optimization.) For now, this function isn't that sophisticated;
%% it just checks that there is really no family in the mibview
%% that the Oid (or any other oids with Oid as prefix) may be
%% included in. Perhaps this function easily could be more
%% intelligent.
%%-----------------------------------------------------------------
is_definitely_not_in_mib_view(Oid, [{SubTree, Mask,?view_included}|T]) ->
    case check_maybe_mask(Oid, SubTree, Mask) of
	true -> false;
	false -> is_definitely_not_in_mib_view(Oid, T)
    end;
is_definitely_not_in_mib_view(Oid, [{SubTree, Mask,?view_excluded}|T]) ->
    is_definitely_not_in_mib_view(Oid, T);
is_definitely_not_in_mib_view(_Oid, []) ->
    true.
    
%%-----------------------------------------------------------------
%% As check_mask, BUT if Oid < SubTree and sofar good, we
%% return true. As Oid get larger we may decide.
%%-----------------------------------------------------------------
check_maybe_mask(Oid, [], Mask) -> true;
check_maybe_mask([X | Xs], [X | Ys], [1 | Ms]) ->
    check_maybe_mask(Xs, Ys, Ms);
check_maybe_mask([X | Xs], [X | Ys], []) ->
    check_maybe_mask(Xs, Ys, []);
check_maybe_mask([X | Xs], [Y | Ys], [0 | Ms]) ->
    check_maybe_mask(Xs, Ys, Ms);
check_maybe_mask([X | Xs], [Y | Ys], _) ->
    false;
check_maybe_mask(_, _, _) -> 
    true.
