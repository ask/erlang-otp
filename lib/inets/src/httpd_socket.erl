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
-module(httpd_socket).
-export([start/1,listen/2,listen/3,accept/2,accept/3,
	 deliver/3,send/3,close/2,
	 peername/2,resolve/1,config/1]).

-include("httpd.hrl").
-include_lib("kernel/include/inet.hrl").

%% start -> ok | {error,Reason}

start(ip_comm) ->
    case inet_db:start() of
	{ok,_Pid} ->
	    ok;
	{error,{already_started,_Pid}} ->
	    ok;
	Error ->
	    Error
    end;
start({ssl,_SSLConfig}) ->
    case ssl:start() of
	{ok,_Pid} ->
	    ok;
	{error,{already_started,_Ssl}} ->
	    ok;
	Error ->
	    Error
    end.

%% listen

listen(SocketType,Port) ->
    listen(SocketType,undefined,Port).

listen(ip_comm,Addr,Port) ->
    case gen_tcp:listen(Port,
			sock_opt(Addr) ++
			[{packet,0},
			 {backlog,128},
			 {reuseaddr,true}]) of
	{ok,ListenSocket} ->
	    ListenSocket;
	Error ->
	    Error
    end;
listen({ssl,SSLConfig},Addr,Port) ->
    ?DEBUG("SSL: Listening to port ~p", [Port]),
    case ssl:listen(Port, sock_opt(Addr)++[{packet,0}|SSLConfig]) of
	{ok,ListenSocket} ->
	    ListenSocket;
	Error ->
	    Error
    end.

sock_opt(undefined) -> [];
sock_opt(Addr) -> [{ip, Addr}].

%% accept

accept(A, B) ->
    accept(A, B, infinity).


accept(ip_comm,ListenSocket, T) ->
    ?DEBUG("IP_COMM: Accept on socket ~p", [ListenSocket]),
    case gen_tcp:accept(ListenSocket, T) of
	{ok,Socket} ->
	    Socket;
	Error ->
	    Error
    end;
accept({ssl,_SSLConfig},ListenSocket, T) ->
    ?DEBUG("SSL: Accept on socket ~p", [ListenSocket]),
    case ssl:accept(ListenSocket, T) of
	{ok,Socket} ->
	    Socket;
	Error ->
	    Error
    end.

%% deliver

deliver(SocketType, Socket, IOListOrBinary)  ->
    case send(SocketType, Socket, IOListOrBinary) of
	{error, _Reason} ->
	    (catch close(SocketType, Socket)), 
	    socket_closed;
	_ ->
	    ok
    end.

send(ip_comm,Socket,Data) ->
    ?DEBUG("send(ip_comm) -> ~p bytes on socket ~p", 
	   [data_size(Data), Socket]),
    gen_tcp:send(Socket,Data);
send({ssl,SSLConfig},Socket,Data) ->
    ?DEBUG("send(ssl) -> ~p bytes on socket ~p", 
	   [data_size(Data), Socket]),
    ssl:send(Socket, Data).

-ifdef(inets_debug).
data_size(L) when list(L) -> 
    httpd_util:flatlength(L);
data_size(B) when binary(B) ->
    size(B);
data_size(O) ->
    {unknown_size,O}.
-endif.


%% peername

peername(ip_comm, Socket) ->
    case inet:peername(Socket) of
	{ok,{{A,B,C,D},Port}} ->
	    PeerName = integer_to_list(A)++"."++integer_to_list(B)++"."++
		integer_to_list(C)++"."++integer_to_list(D),
	    ?DEBUG("IP_COMM: Peername on socket ~p: ~p",
		   [Socket,{Port,PeerName}]),
	    {Port,PeerName};
	{error,Reason} ->
	    {-1,"unknown"}
    end;
peername({ssl,_SSLConfig},Socket) ->
    case ssl:peername(Socket) of
	{ok,{{A,B,C,D},Port}} ->
	    PeerName = integer_to_list(A)++"."++integer_to_list(B)++"."++
		integer_to_list(C)++"."++integer_to_list(D),
	    ?DEBUG("SSL: Peername on socket ~p: ~p", 
		   [Socket, {Port,PeerName}]),
	    {Port,PeerName};
	{error,_Reason} ->
	    {-1,"unknown"}
    end.

%% resolve

resolve(_) ->
    {ok,Name} = inet:gethostname(),
    Name.

%% close

close(ip_comm,Socket) ->
    ?DEBUG("IP_COMM: Close socket ~p", [Socket]),
    case (catch gen_tcp:close(Socket)) of
	ok ->                  ok;
	{error,Reason} ->      {error,Reason};
	{'EXIT',{noproc,_}} -> {error,closed};
	{'EXIT',Reason} ->     {error,Reason};
	Otherwise ->           {error,Otherwise}
    end;
close({ssl,_SSLConfig},Socket) ->
    ?DEBUG("SSL: Close socket ~p", [Socket]),
    case (catch ssl:close(Socket)) of
	ok ->                  ok;
	{error,Reason} ->      {error,Reason};
	{'EXIT',{noproc,_}} -> {error,closed};
	{'EXIT',Reason} ->     {error,Reason};
	Otherwise ->           {error,Otherwise}
    end.

%% config (debug: {certfile, "/var/tmp/server_root/conf/ssl_server.pem"})

config(ConfigDB) ->
    case httpd_util:lookup(ConfigDB,com_type,ip_comm) of
	ssl ->
	    case ssl_certificate_file(ConfigDB) of
		undefined ->
		    {error,
		     ?NICE("Directive SSLCertificateFile "
			   "not found in the config file")};
		SSLCertificateFile ->
		    {ssl,
		     SSLCertificateFile++ssl_certificate_key_file(ConfigDB)++
		     ssl_verify_client(ConfigDB)}
	    end;
	ip_comm ->
	    ip_comm
    end.

ssl_certificate_file(ConfigDB) ->
    case httpd_util:lookup(ConfigDB,ssl_certificate_file) of
	undefined ->
	    undefined;
	SSLCertificateFile ->
	    [{certfile,SSLCertificateFile}]
    end.

ssl_certificate_key_file(ConfigDB) ->
    case httpd_util:lookup(ConfigDB,ssl_certificate_key_file) of
	undefined ->
	    [];
	SSLCertificateKeyFile ->
	    [{keyfile,SSLCertificateKeyFile}]
    end.

ssl_verify_client(ConfigDB) ->
    case httpd_util:lookup(ConfigDB,ssl_verify_client) of
	undefined ->
	    [];
	SSLVerifyClient ->
	    [{verify,SSLVerifyClient}]
    end.


