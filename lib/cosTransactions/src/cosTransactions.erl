%%--------------------------------------------------------------------
%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1999-2009. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%
%%
%%----------------------------------------------------------------------
%% File    : cosTransactions.erl
%% Purpose : Initialize the 'cosTransactions' application
%%----------------------------------------------------------------------

-module(cosTransactions).

%%--------------- INCLUDES -----------------------------------
%% Local
-include_lib("ETraP_Common.hrl").
-include_lib("CosTransactions.hrl").
%%--------------- EXPORTS-------------------------------------
%% cosTransactions API external
-export([start/0, stop/0, start_factory/1, start_factory/0, stop_factory/1]).

%% Application callbacks
-export([start/2, init/1, stop/1]).

%%------------------------------------------------------------
%% function : start/stop
%% Arguments: 
%% Returns  : 
%% Effect   : Starts or stops the cosTRansaction application.
%%------------------------------------------------------------

start() ->
    application:start(cosTransactions).
stop() ->
    application:stop(cosTransactions).

%%------------------------------------------------------------
%% function : start_factory 
%% Arguments: none or an argumentlist which by default is defined
%%            in ETraP_Common.hrl, i.e., '?tr_FAC_DEF'
%% Returns  : ObjectRef | {'EXCEPTION', _} | {'EXIT', Reason}
%% Effect   : Starts a CosTransactions_TransactionFactory
%%------------------------------------------------------------

start_factory() ->
    ?tr_start_child(?SUP_FAC(?tr_FAC_DEF)).
    
start_factory(Args) when list(Args) ->
    ?tr_start_child(?SUP_FAC(Args));
start_factory(Args) ->
    ?tr_error_msg("applications:start( ~p ) failed. Bad parameters~n", [Args]),
    exit("applications:start failed. Bad parameters").

%%------------------------------------------------------------
%% function : stop_factory 
%% Arguments: Factory Object Reference
%% Returns  : ok | {'EXCEPTION', _}
%% Effect   : 
%%------------------------------------------------------------

stop_factory(Fac)->
    corba:dispose(Fac).

%%------------------------------------------------------------
%% function : start
%% Arguments: Type - see module application
%%            Arg  - see module application
%% Returns  : 
%% Effect   : Module callback for application
%%------------------------------------------------------------

start(_, _) ->
    supervisor:start_link({local, ?SUPERVISOR_NAME}, cosTransactions, app_init).


%%------------------------------------------------------------
%% function : stop
%% Arguments: Arg - see module application
%% Returns  : 
%% Effect   : Module callback for application
%%------------------------------------------------------------

stop(_) ->
    ok.

%%------------------------------------------------------------
%% function : init
%% Arguments: 
%% Returns  : 
%% Effect   : 
%%------------------------------------------------------------

%% Starting using create_factory/X
init(own_init) ->
    {ok,{?SUP_FLAG, [?SUP_CHILD]}};
%% When starting as an application.
init(app_init) ->
    {ok,{?SUP_FLAG, [?SUP_CHILD]}}.


%%--------------- END OF MODULE ------------------------------
