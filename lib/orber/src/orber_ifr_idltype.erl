%%--------------------------------------------------------------------
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
%%----------------------------------------------------------------------
%% File    : orber_ifr_idltype.erl
%% Author  : Per Danielsson <pd@gwaihir>
%% Purpose : Code for Idltype
%% Created : 14 May 1997 by Per Danielsson <pd@gwaihir>
%%----------------------------------------------------------------------

-module(orber_ifr_idltype).

-export(['_get_def_kind'/1,
	 destroy/1,
	 cleanup_for_destroy/1,			%not in CORBA 2.0
	 '_get_type'/1,
	 '_get_type_def'/1
	]).

-import(orber_ifr_utils,[get_field/2]).

-include("orber_ifr.hrl").
-include("ifr_objects.hrl").

%%%======================================================================
%%% IDLType (IRObject)

%%%----------------------------------------------------------------------
%%% Interfaces inherited from IRObject

'_get_def_kind'({ObjType, ObjID}) ?tcheck(ir_IDLType, ObjType) ->
    orber_ifr_irobject:'_get_def_kind'({ObjType, ObjID}).

%%% Don't type check the object reference. We need to be able to
%%% handle several types of objects that inherit from IDLType.

destroy(IDLType_objref) ->
    F = fun() -> ObjList = cleanup_for_destroy(IDLType_objref),
		 orber_ifr_irobject:destroy(ObjList)
	end,
    orber_ifr_utils:ifr_transaction_write(F).

cleanup_for_destroy(IDLType_objref) ->
    [IDLType_objref].

%%%----------------------------------------------------------------------
%%% Non-inherited interfaces

%% What is this ? You cannot check this for ir_IDLType here !
%% ( an object type cannot be both .... ) 
%%'_get_type'({ObjType,ObjID}) ?tcheck(ir_IDLType, ObjType) ->
%%    get_field({ObjType,ObjID},type).


'_get_type'({ObjType,ObjID}) ->
    get_field({ObjType,ObjID},type).

'_get_type_def'({ObjType,ObjID}) ->
    get_field({ObjType,ObjID},type_def).
