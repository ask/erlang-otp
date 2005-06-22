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
-module(snmp_note_store).

-include("snmp_debug.hrl").
-include("snmp_verbosity.hrl").

%% External exports
-export([start_link/3, get_note/2, set_note/4, verbosity/2]).

%% Internal exports
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2, 
	 terminate/2, 
	 code_change/3]).

-export([timer/3]).

-define(timeout, 30000).  % Perform gc twice in a minute.

-ifndef(default_verbosity).
-define(default_verbosity,silence).
-endif.

-ifdef(snmp_debug).
-define(GS_START_LINK(Args),
	gen_server:start_link(?MODULE, Args, [{debug,[trace]}])).
-else.
-define(GS_START_LINK(Args),
	gen_server:start_link(?MODULE, Args, [])).
-endif.


-record(state, {mod, notes, timer, timeout, active = false}).


%%%-----------------------------------------------------------------
%%% Implements a database for notes with a lifetime. Once in a
%%% while, the database will be gc:ed, to get rid of old notes.
%%% This database will not contain much data.
%%% Options is a list of Option, where Option is
%%%   {verbosity, silence|log|debug|trace} % undocumented feature
%%%-----------------------------------------------------------------
start_link(Prio, Mod, Opts) ->
    ?d("start_link -> entry with"
	"~n   Prio: ~p"
	"~n   Mod:  ~p"
	"~n   Opts: ~p", [Prio, Mod, Opts]),
    ?GS_START_LINK([Prio, Mod, Opts]).


%%-----------------------------------------------------------------
%% Interface functions.
%%-----------------------------------------------------------------
get_note(Pid, Key) ->
    gen_server:call(Pid, {get_note, Key}, infinity).
%% Lifetime is in 1/10 sec.
set_note(Pid, Lifetime, Key, Value) ->
    gen_server:call(Pid, {set_note, Lifetime, Key, Value}, infinity).

verbosity(Pid, Verbosity) -> 
    gen_server:cast(Pid,{verbosity,Verbosity}).


init([Prio, Mod, Opts]) ->
    ?d("init -> entry with"
	"~n   Prio: ~p"
	"~n   Mod:  ~p"
	"~n   Opts: ~p", [Prio, Mod, Opts]),
    case (catch do_init(Prio, Mod, Opts)) of
	{ok, State} ->
	    {ok, State};
	E ->
	    error_msg("failed starting note-store: ~n~p", [E]),
	    {stop, E}
    end.

do_init(Prio, Mod, Opts) ->
    process_flag(trap_exit, true),
    process_flag(priority, Prio),
    put(sname, get_sname(Opts)),
    put(verbosity, get_verbosity(Opts)),
    ?vlog("starting",[]),
    Notes   = ets:new(snmp_note_store, [set, protected]), 
    Timeout = get_timeout(Opts),
    State   = #state{mod     = Mod, 
		     notes   = Notes, 
		     timeout = Timeout, 
		     timer   = start_timer(Timeout)},
    ?vdebug("started",[]),
    {ok, State}.


%%-----------------------------------------------------------------
%% A note is any internal information that has to be
%% stored for some time (the Lifetime).
%% A note is stored in ets as {Key, {BestBefore, Value}},
%% where BestBefore is currentTime + Lifetime. 
%% A GC-op can destroy any notes with CurTime > BestBore.
%% Lifetime is in centiseconds or infinity, in which case
%% the note is eternal.
%%-----------------------------------------------------------------
handle_call({set_note, Lifetime, Key, Value}, _From, 
	    #state{mod = Mod, notes = Notes} = State) 
  when integer(Lifetime) ->
    ?vlog("set note <~p,~p> with life time ~p",[Key,Value,Lifetime]),
    RealUpTime = snmp_misc:now(cs) - Mod:system_start_time(),
    ?vtrace("handle_call(set_note) -> RealUpTime: ~p",[RealUpTime]),
    BestBefore = RealUpTime + Lifetime,
    ?vtrace("handle_call(set_note) -> BestBefore: ~p",[BestBefore]),
    Val = ets:insert(Notes, {Key, {BestBefore, Value}}),
    NState = activate_timer(State),
    {reply, Val, NState};

handle_call({set_note, infinity, Key, Value}, _From, State) ->
    ?vlog("set note <~p,~p>",[Key,Value]),
    Val = ets:insert(State#state.notes, {Key, {infinity, Value}}),
    ?vdebug("set note; old value: ~p",[Val]),
    {reply, Val, State};

handle_call({get_note, Key}, _From, 
	    #state{mod = Mod, notes = Notes} = State) ->
    ?vlog("get note ~p",[Key]),
    Val = handle_get_note(Notes, Mod, Key),
    ?vdebug("get note: ~p",[Val]),
    {reply, Val, State};

handle_call(stop, _From, State) ->
    ?vlog("stop",[]),
    {stop, normal, ok, State};

handle_call(Req, From, State) ->
    info_msg("received unexpected request from ~p: ~n~p",[From, Req]),
    {reply, {error, {unknown_request, Req}}, State}.


handle_cast({verbosity,Verbosity}, State) ->
    ?vlog("verbosity: ~p -> ~p",[get(verbosity),Verbosity]),
    put(verbosity,snmp_verbosity:validate(Verbosity)),
    {noreply, State};
    
handle_cast(Msg, State) ->
    info_msg("received unexpected message: ~n~p",[Msg]),
    {noreply, State}.
    

%%-----------------------------------------------------------------
%% If there are no possible garbage left, we don't
%% have to wait for timeout, and perform another
%% gc, because we won't do anything. So
%% we switch the timeout off in that case.
%% It will be switched on as soon as we get some
%% other message.
%%-----------------------------------------------------------------
handle_info(timeout, State) ->
    ?vdebug("timeout",[]),
    case gc(State) of
	nothing_left ->
	    NState = deactivate_timer(State),
	    {noreply, NState};
	work_to_do ->
	    NState = activate_timer(State),
	    {noreply, NState}
    end;

handle_info({'EXIT', Pid, Reason}, 
	    #state{timer = Pid, timeout = Timeout} = State) ->
    ?vinfo("exit message from the timer process ~p for reason ~p",
	   [Pid, Reason]),
    set_state(State#state{timer = start_timer(Timeout)});

handle_info({'EXIT',Pid,Reason}, State) ->
    ?vlog("exit message from ~p for reason ~p",[Pid,Reason]),
    {noreply, State};

handle_info(Info, State) ->
    info_msg("received unexpected info: ~n~p",[Info]),
    {noreply, State}.


set_state(S) ->
    case gc(S) of
	nothing_left ->
	    NState = deactivate_timer(S),
	    {noreply, NState};
	work_to_do ->
	    NState = activate_timer(S),
	    {noreply, NState}
    end.


terminate(Reason, _State) ->
    ?vdebug("terminate: ~p",[Reason]),
    ok.


%%----------------------------------------------------------
%% Code change
%%----------------------------------------------------------

% downgrade
code_change({down, _Vsn}, State, _Extra) ->
    NState = activate_timer(deactivate_timer(State)),
    {ok, NState};

% upgrade
code_change(_Vsn, State, _Extra) ->
    process_flag(trap_exit, true),
    NState = restart_timer(State),
    {ok, NState}.


%%----------------------------------------------------------
%% Timer
%%----------------------------------------------------------

activate_timer(#state{timer = Pid, active = false} = State) ->
    Pid ! activate,
    receive
	activated -> ok
    end,
    State#state{active = true};
activate_timer(State) ->
    State.

deactivate_timer(#state{timer = Pid, active = true} = State) ->
    Pid ! deactivate,
    receive
	deactivated -> ok
    end,
    State#state{timeout = false};
deactivate_timer(State) ->
    State.

start_timer(Timeout) ->
    spawn_link(?MODULE, timer, [self(), passive, Timeout]).

%% Kill, restart and activate timer.
restart_timer(#state{timer = Pid, timeout = Timeout} = State) ->
    ?d("restart_timer -> kill current timer process ~p",[Pid]),
    exit(Pid, kill),
    ?d("restart_timer -> await acknowledgement",[]),
    receive
	{'EXIT', Pid, _Reason} ->
	    ok
    end,
    ?d("restart_timer -> start a new timer process",[]),
    activate_timer(State#state{timer = start_timer(Timeout), active = false}).

timer(Pid, passive, Timeout) ->
    receive
	deactivate ->
	    ?d("timer(passive) -> deactivate request, just send ack",[]),
	    Pid ! deactivated,
	    ?MODULE:timer(Pid, passive, Timeout);

	activate ->
	    ?d("timer(deactive) -> activate request, send ack",[]),
	    Pid ! activated,
	    ?d("timer(deactive) -> activate",[]),
	    ?MODULE:timer(Pid, active, Timeout)		% code replacement
    after
	Timeout ->
	    ?d("timer(deactive) -> timeout",[]),
	    ?MODULE:timer(Pid, passive, Timeout)
    end;
timer(Pid, active, Timeout) ->
    receive
	activate ->
	    ?d("timer(active) -> activate request, just send ack",[]),
	    Pid ! activated,
	    ?MODULE:timer(Pid, active, Timeout);

	deactivate ->
	    ?d("timer(active) -> deactivate request, send ack",[]),
	    Pid ! deactivated,
	    ?d("timer(active) -> deactivate",[]),
	    ?MODULE:timer(Pid, passive, Timeout)
    after
	Timeout ->
	    ?d("timer(active) -> timeout",[]),
	    Pid ! timeout,
	    ?MODULE:timer(Pid, active, Timeout)
    end.
    

handle_get_note(Notes, Mod, Key) ->
    case ets:lookup(Notes, Key) of
	[{Key, {infinity, Val}}] ->
	    Val;
	[{Key, {BestBefore, Val}}] ->
	    ?vtrace("get note -> BestBefore: ~w", [BestBefore]),
	    StartTime = Mod:system_start_time(), 
	    ?vtrace("get note -> StartTime: ~w", [StartTime]),
	    case (snmp_misc:now(cs) - StartTime) of
		Now when BestBefore >= Now ->
		    ?vtrace("get note -> Now: ~w", [Now]),
		    Val;
		_ ->
		    ets:delete(Notes, Key),
		    undefined
	    end;
	[] -> undefined
    end.


%%-----------------------------------------------------------------
%% Clean up all old notes in the database.
%%-----------------------------------------------------------------
gc(#state{mod = Mod, notes = Notes}) ->
    RealUpTime = snmp_misc:now(cs) - Mod:system_start_time(),
    gc(nothing_left, ets:tab2list(Notes), Notes, RealUpTime).

gc(Flag, [{_Key, {infinity, _}} | T], Tab, Now) -> gc(Flag, T, Tab, Now);
gc(Flag, [{Key, {BestBefore, _}} | T], Tab, Now) 
  when integer(BestBefore), BestBefore < Now ->
    ets:delete(Tab, Key),
    gc(Flag, T, Tab, Now);
gc(_Flag, [_ | T], Tab, Now) -> gc(work_to_do, T, Tab, Now);
gc(Flag, [], _Tab, _Now) -> Flag.
    
    
%%-----------------------------------------------------------------

error_msg(F, A) ->
    error_logger:error_msg("~w: " ++ F ++ "~n", [?MODULE|A]).

info_msg(F, A) ->
    error_logger:info_msg("~w: " ++ F ++ "~n", [?MODULE|A]).


%%-----------------------------------------------------------------

get_verbosity(Opts) ->
    snmp_misc:get_option(verbosity,Opts,?default_verbosity).

get_sname(Opts) ->
    snmp_misc:get_option(sname,Opts,ns).

get_timeout(Opts) ->
    snmp_misc:get_option(timeout,Opts,?timeout).

 