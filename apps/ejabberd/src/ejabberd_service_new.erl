%%%----------------------------------------------------------------------
%%% File    : ejabberd_service.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : External component management (XEP-0114)
%%% Created :  6 Dec 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------
-module(ejabberd_service_new).
-author('alexey@process-one.net').

-define(GEN_FSM, p1_fsm).

-behaviour(?GEN_FSM).

%% External exports
-export([start/2,
         start_link/2,
         send_text/2,
         send_element/2,
         socket_type/0]).

%% gen_fsm callbacks
-export([init/1,
         wait_for_stream/2,
         wait_for_handshake/2,
         stream_established/2,
         handle_event/3,
         handle_sync_event/4,
         code_change/4,
         handle_info/3,
         terminate/3,
         print_state/1]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-record(state, {socket,
                sockmod     :: ejabberd:sockmod(),
                streamid,
                hosts       :: list(),
                password    :: binary(),
                access,
                check_from
              }).
-type state() :: #state{}.

-type statename() :: wait_for_stream
                   | wait_for_handshake
                   | stream_established.
%% FSM handler return value
-type fsm_return() :: {'stop', Reason :: 'normal', state()}
                    | {'next_state', statename(), state()}
                    | {'next_state', statename(), state(), Timeout :: integer()}.
%-define(DBGFSM, true).

-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

-define(STREAM_HEADER,
        <<"<?xml version='1.0'?>"
          "<stream:stream "
          "from='~s' "
          "id='~s' "
          "to='~s' "
          "version='1.0' "
          "xml:lang='en' "
          "xmlns='jabber:client' "
          "xmlns:stream='http://etherx.jabber.org/streams'>">>
       ).

-define(STREAM_FEATURES,
        <<"<stream:features>"
          "<bind xmlns='urn:xmpp:component:0'>"
          "<required/>"
          "</bind>"
          "</stream:features>">>
       ).

-define(STREAM_TRAILER, <<"</stream:stream>">>).

-define(INVALID_HEADER_ERR,
        <<"<stream:stream "
        "xmlns:stream='http://etherx.jabber.org/streams'>"
        "<stream:error>Invalid Stream Header</stream:error>"
        "</stream:stream>">>
       ).

-define(INVALID_HANDSHAKE_ERR,
        <<"<stream:error>"
        "<not-authorized xmlns='urn:ietf:params:xml:ns:xmpp-streams'/>"
        "<text xmlns='urn:ietf:params:xml:ns:xmpp-streams' xml:lang='en'>"
        "Invalid Handshake</text>"
        "</stream:error>"
        "</stream:stream>">>
       ).

-define(INVALID_XML_ERR,
        xml:element_to_binary(?SERR_XML_NOT_WELL_FORMED)).
-define(INVALID_NS_ERR,
        xml:element_to_binary(?SERR_INVALID_NAMESPACE)).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
-spec start(_,_) -> {'error',_} | {'ok','undefined' | pid()} | {'ok','undefined' | pid(),_}.
start(SockData, Opts) ->
    supervisor:start_child(ejabberd_service_new_sup, [SockData, Opts]).


-spec start_link(_, list()) -> 'ignore' | {'error',_} | {'ok',pid()}.
start_link(SockData, Opts) ->
    ?GEN_FSM:start_link(ejabberd_service_new, [SockData, Opts],
                        fsm_limit_opts(Opts) ++ ?FSMOPTS).


socket_type() ->
    xml_stream.

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%%----------------------------------------------------------------------
-spec init([list() | {atom() | tuple(),_},...]) -> {'ok','wait_for_stream',state()}.
init([{SockMod, Socket}, Opts]) ->
    ?INFO_MSG("(~w) External service connected", [Socket]),
    Access = case lists:keysearch(access, 1, Opts) of
                 {value, {_, A}} -> A;
                 _ -> all
             end,
    {Hosts, Password} =
        case lists:keysearch(hosts, 1, Opts) of
            {value, {_, Hs, HOpts}} ->
                case lists:keysearch(password, 1, HOpts) of
                    {value, {_, P}} ->
                        {Hs, P};
                    _ ->
                        % TODO: generate error
                        false
                end;
            _ ->
                case lists:keysearch(host, 1, Opts) of
                    {value, {_, H, HOpts}} ->
                        case lists:keysearch(password, 1, HOpts) of
                            {value, {_, P}} ->
                                {[H], P};
                            _ ->
                                % TODO: generate error
                                false
                        end;
                    _ ->
                        % TODO: generate error
                        false
                end
        end,
    Shaper = case lists:keysearch(shaper_rule, 1, Opts) of
                 {value, {_, S}} -> S;
                 _ -> none
             end,
    CheckFrom = case lists:keysearch(service_check_from, 1, Opts) of
                 {value, {_, CF}} -> CF;
                 _ -> true
             end,
    SockMod:change_shaper(Socket, Shaper),
    {ok, wait_for_stream, #state{socket = Socket,
                                 sockmod = SockMod,
                                 streamid = new_id(),
                                 hosts = [iolist_to_binary(H) || H <- Hosts],
                                 password = Password,
                                 access = Access,
                                 check_from = CheckFrom
                                }}.

%%----------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------

-spec wait_for_stream(ejabberd:xml_stream_item(), state()) -> fsm_return().
wait_for_stream({xmlstreamstart, _Name, Attrs}, StateData) ->
    case xml:get_attr_s(<<"xmlns">>, Attrs) of
        <<"jabber:client">> ->
            %% TODO: Check if the 'from' equals to at least one of defined hosts
            To = xml:get_attr_s(<<"from">>, Attrs),
            From = xml:get_attr_s(<<"to">>, Attrs),
            Header = io_lib:format(?STREAM_HEADER,
                                   [xml:crypt(From),
                                    StateData#state.streamid,
                                    xml:crypt(To)]),
            send_text(StateData, Header),
            send_text(StateData, ?STREAM_FEATURES),
            {next_state, wait_for_handshake, StateData};
        _ ->
            send_text(StateData, ?INVALID_HEADER_ERR),
            {stop, normal, StateData}
    end;
wait_for_stream({xmlstreamerror, _}, StateData) ->
    Header = io_lib:format(?STREAM_HEADER,
                           [<<"none">>, ?MYNAME]),
    send_text(StateData,<<(iolist_to_binary(Header))/binary,
                           (?INVALID_XML_ERR)/binary,(?STREAM_TRAILER)/binary>>),
    {stop, normal, StateData};
wait_for_stream(closed, StateData) ->
    {stop, normal, StateData}.


-spec wait_for_handshake(ejabberd:xml_stream_item(), state()) -> fsm_return().
wait_for_handshake({xmlstreamelement, El}, StateData) ->
    #xmlel{name = Name, children = Els} = El,
    case {Name, xml:get_cdata(Els)} of
        {<<"handshake">>, Digest} ->
            case list_to_binary(sha:sha(StateData#state.streamid ++
                         StateData#state.password)) of
                Digest ->
                    send_text(StateData, <<"<handshake/>">>),
                    lists:foreach(
                      fun(H) ->
                              ejabberd_router:register_route(H),
                              ?INFO_MSG("Route registered for service ~p~n", [H])
                      end, StateData#state.hosts),
                    {next_state, stream_established, StateData};
                _ ->
                    send_text(StateData, ?INVALID_HANDSHAKE_ERR),
                    {stop, normal, StateData}
            end;
        _ ->
            {next_state, wait_for_handshake, StateData}
    end;
wait_for_handshake({xmlstreamend, _Name}, StateData) ->
    {stop, normal, StateData};
wait_for_handshake({xmlstreamerror, _}, StateData) ->
    send_text(StateData,<<(?INVALID_XML_ERR)/binary,(?STREAM_TRAILER)/binary>>),
    {stop, normal, StateData};
wait_for_handshake(closed, StateData) ->
    {stop, normal, StateData}.


-spec stream_established(ejabberd:xml_stream_item(), state()) -> fsm_return().
stream_established({xmlstreamelement, El}, StateData) ->
    NewEl = jlib:remove_attr(<<"xmlns">>, El),
    #xmlel{name = Name, attrs = Attrs} = NewEl,
    From = xml:get_attr_s(<<"from">>, Attrs),
    FromJID = case StateData#state.check_from of
                  %% If the admin does not want to check the from field
                  %% when accept packets from any address.
                  %% In this case, the component can send packet of
                  %% behalf of the server users.
                  false -> jlib:binary_to_jid(From);
                  %% The default is the standard behaviour in XEP-0114
                  _ ->
                      FromJID1 = jlib:binary_to_jid(From),
                      case FromJID1 of
                          #jid{lserver = Server} ->
                              case lists:member(Server, StateData#state.hosts) of
                                  true -> FromJID1;
                                  false -> error
                              end;
                          _ -> error
                      end
              end,
    To = xml:get_attr_s(<<"to">>, Attrs),
    ToJID = case To of
                <<>> -> error;
                _ -> jlib:binary_to_jid(To)
            end,
    if ((Name == <<"iq">>) or
        (Name == <<"message">>) or
        (Name == <<"presence">>)) and
       (ToJID /= error) and (FromJID /= error) ->
            ejabberd_router:route(FromJID, ToJID, NewEl);
       true ->
            ?INFO_MSG("Not valid Name (~p) or error in FromJID (~p) or ToJID (~p)~n", [Name, FromJID, ToJID]),
            Err = jlib:make_error_reply(NewEl, ?ERR_BAD_REQUEST),
            send_element(StateData, Err),
            error
    end,
    {next_state, stream_established, StateData};
stream_established({xmlstreamend, _Name}, StateData) ->
    % TODO ??
    {stop, normal, StateData};
stream_established({xmlstreamerror, _}, StateData) ->
    send_text(StateData, <<(?INVALID_XML_ERR)/binary,(?STREAM_TRAILER)/binary>>),
    {stop, normal, StateData};
stream_established(closed, StateData) ->
    % TODO ??
    {stop, normal, StateData}.


%%----------------------------------------------------------------------
%% Func: StateName/3
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%%----------------------------------------------------------------------
%state_name(Event, From, StateData) ->
%    Reply = ok,
%    {reply, Reply, state_name, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%%----------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.


code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_info({send_text, Text}, StateName, StateData) ->
    send_text(StateData, Text),
    {next_state, StateName, StateData};
handle_info({send_element, El}, StateName, StateData) ->
    send_element(StateData, El),
    {next_state, StateName, StateData};
handle_info({route, From, To, Packet}, StateName, StateData) ->
    case acl:match_rule(global, StateData#state.access, From) of
        allow ->
           #xmlel{name =Name, attrs = Attrs,children = Els} = Packet,
            Attrs2 = jlib:replace_from_to_attrs(jlib:jid_to_binary(From),
                                                jlib:jid_to_binary(To),
                                                Attrs),
            Text = xml:element_to_binary( #xmlel{name = Name, attrs = Attrs2,children = Els}),
            send_text(StateData, Text);
        deny ->
            Err = jlib:make_error_reply(Packet, ?ERR_NOT_ALLOWED),
            ejabberd_router:route_error(To, From, Err, Packet)
    end,
    {next_state, StateName, StateData};
handle_info(Info, StateName, StateData) ->
    ?ERROR_MSG("Unexpected info: ~p", [Info]),
    {next_state, StateName, StateData}.


%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(Reason, StateName, StateData) ->
    ?INFO_MSG("terminated: ~p", [Reason]),
    case StateName of
        stream_established ->
            lists:foreach(
              fun(H) ->
                      ejabberd_router:unregister_route(H)
              end, StateData#state.hosts);
        _ ->
            ok
    end,
    (StateData#state.sockmod):close(StateData#state.socket),
    ok.

%%----------------------------------------------------------------------
%% Func: print_state/1
%% Purpose: Prepare the state to be printed on error log
%% Returns: State to print
%%----------------------------------------------------------------------
print_state(State) ->
    State.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

-spec send_text(state(), binary()) -> binary().
send_text(StateData, Text) ->
    (StateData#state.sockmod):send(StateData#state.socket, Text).


-spec send_element(state(), jlib:xmlel()) -> binary().
send_element(StateData, El) ->
    send_text(StateData, xml:element_to_binary(El)).


-spec new_id() -> string().
new_id() ->
    randoms:get_string().


-spec fsm_limit_opts(maybe_improper_list()) -> [{'max_queue',integer()}].
fsm_limit_opts(Opts) ->
    case lists:keysearch(max_fsm_queue, 1, Opts) of
        {value, {_, N}} when is_integer(N) ->
            [{max_queue, N}];
        _ ->
            case ejabberd_config:get_local_option(max_fsm_queue) of
                N when is_integer(N) ->
                    [{max_queue, N}];
                _ ->
                    []
            end
    end.

