-module(iroh_dist_controller).

-define(MAX_PORT_CHUNK, 16 * 1024).

-export([start/4, start/5, start_link/4,
         supervisor/2, send/2, recv/3, handshake_complete/2,
         tick/1, getstat/1, close/1,
         frame/2, feed/3]).

start(PortMod, Port, StreamId, Credit) ->
    start(PortMod, Port, StreamId, Credit, true).

start(PortMod, Port, StreamId, Credit, Subscribe) ->
    Parent = self(),
    Tag = make_ref(),
    Pid = spawn(fun() -> init(Parent, Tag, PortMod, Port, StreamId, Credit, Subscribe) end),
    receive
        {Tag, ok} -> {ok, Pid};
        {Tag, {error, Reason}} -> {error, Reason}
    end.

start_link(PortMod, Port, StreamId, Credit) ->
    Parent = self(),
    Tag = make_ref(),
    Pid = spawn_link(fun() -> init(Parent, Tag, PortMod, Port, StreamId, Credit, true) end),
    receive
        {Tag, ok} -> {ok, Pid};
        {Tag, {error, Reason}} -> {error, Reason}
    end.

supervisor(Pid, Supervisor) -> call(Pid, {supervisor, Supervisor}, infinity).
send(Pid, Packet) -> call(Pid, {send, Packet}, infinity).
recv(Pid, Length, Timeout) -> call(Pid, {recv, Length, Timeout}, infinity).
handshake_complete(Pid, DHandle) -> call(Pid, {handshake_complete, DHandle}, infinity).
tick(Pid) -> call(Pid, tick, infinity).
getstat(Pid) -> call(Pid, getstat, infinity).
close(Pid) -> call(Pid, close, infinity).

frame(2, Payload) ->
    Size = iolist_size(Payload),
    true = Size < (1 bsl 16),
    iolist_to_binary([<<Size:16>>, Payload]);
frame(4, Payload) ->
    Size = iolist_size(Payload),
    true = Size < (1 bsl 32),
    iolist_to_binary([<<Size:32>>, Payload]).

feed(HeaderSize, Buffer, Chunk) when HeaderSize =:= 2; HeaderSize =:= 4 ->
    parse_frames(HeaderSize, <<Buffer/binary, Chunk/binary>>, []).

parse_frames(2, <<Size:16, Payload:Size/binary, Rest/binary>>, Acc) ->
    parse_frames(2, Rest, [Payload | Acc]);
parse_frames(4, <<Size:32, Payload:Size/binary, Rest/binary>>, Acc) ->
    parse_frames(4, Rest, [Payload | Acc]);
parse_frames(_, Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

init(Parent, Tag, PortMod, Port, StreamId, Credit, Subscribe) ->
    process_flag(trap_exit, true),
    case maybe_subscribe(Subscribe, PortMod, Port) of
        ok ->
            Monitor = erlang:monitor(process, Port),
            Parent ! {Tag, ok},
            loop(#{port_mod => PortMod, port => Port, port_monitor => Monitor,
                   stream_id => StreamId, credit => Credit, mode => handshake,
                   buffer => <<>>, waiter => undefined, supervisor => undefined,
                   dhandle => undefined, pending_out => <<>>, dist_ready => false,
                   tick_pending => false, recv_count => 0, send_count => 0,
                   subscribe => Subscribe});
        Error ->
            Parent ! {Tag, Error}
    end.

maybe_subscribe(true, PortMod, Port) -> PortMod:subscribe(Port, self());
maybe_subscribe(false, _PortMod, _Port) -> ok.

loop(State) ->
    receive
        {call, From, Ref, Request} ->
            handle_call(Request, From, Ref, State);
        {cancel_recv, Ref} ->
            loop(cancel_waiter(Ref, State));
        {recv_timeout, Ref} ->
            loop(timeout_waiter(Ref, State));
        {iroh_dist, Event} ->
            handle_event(Event, State);
        dist_data ->
            loop(flush_output(State#{dist_ready := true}));
        {'DOWN', Monitor, process, _Port, Reason}
          when Monitor =:= map_get(port_monitor, State) ->
            exit({port_down, Reason});
        {'EXIT', Supervisor, Reason}
          when Supervisor =:= map_get(supervisor, State) ->
            terminate_stream(State),
            exit(normalize_exit(Reason));
        _Other ->
            loop(State)
    end.

handle_call({supervisor, Supervisor}, From, Ref, State) when is_pid(Supervisor) ->
    link(Supervisor),
    reply(From, Ref, ok),
    loop(State#{supervisor := Supervisor});
handle_call({send, Packet}, From, Ref, #{mode := handshake} = State) ->
    {Result, State1} = send_bytes(frame(2, Packet), State),
    reply(From, Ref, Result),
    loop(State1);
handle_call({recv, 0, Timeout}, From, Ref, #{mode := handshake} = State) ->
    case take_one(2, map_get(buffer, State)) of
        {ok, Packet, Rest} ->
            reply(From, Ref, {ok, binary_to_list(Packet)}),
            loop(State#{buffer := Rest, recv_count := map_get(recv_count, State) + 1});
        more ->
            Timer = recv_timer(Timeout, Ref),
            loop(State#{waiter := {From, Ref, Timer}})
    end;
handle_call({handshake_complete, DHandle}, From, Ref, State) ->
    false = erlang:dist_ctrl_set_opt(DHandle, get_size, true),
    State1 = put_packet4(State#{mode := up, dhandle := DHandle}),
    ok = erlang:dist_ctrl_get_data_notification(DHandle),
    reply(From, Ref, ok),
    loop(State1);
handle_call(tick, From, Ref, State) ->
    reply(From, Ref, ok),
    loop(flush_output(State#{tick_pending := true}));
handle_call(getstat, From, Ref, State) ->
    Pending = case map_get(pending_out, State) of <<>> -> 0; _ -> 1 end,
    reply(From, Ref, {ok, map_get(recv_count, State), map_get(send_count, State), Pending}),
    loop(State);
handle_call(close, From, Ref, State) ->
    reply(From, Ref, ok),
    terminate_stream(State),
    exit(normal);
handle_call(_Request, From, Ref, State) ->
    reply(From, Ref, {error, bad_request}),
    loop(State).

handle_event(#{<<"stream_id">> := StreamId} = Event,
             #{stream_id := StreamId} = State) ->
    handle_stream_event(Event, State);
handle_event(_Event, State) ->
    loop(State).

handle_stream_event(#{<<"event">> := <<"dist_data">>, <<"bytes">> := Hex}, State) ->
    Data = binary:decode_hex(Hex),
    State1 = consume_input(Data, State),
    case port_call(dist_credit, [map_get(stream_id, State), byte_size(Data)], State) of
        {ok, _} -> loop(State1);
        Error ->
            terminate_stream(State1),
            exit({dist_credit, Error})
    end;
handle_stream_event(#{<<"event">> := <<"dist_credit">>, <<"bytes">> := Bytes}, State)
  when is_integer(Bytes), Bytes >= 0 ->
    loop(flush_output(State#{credit := map_get(credit, State) + Bytes}));
handle_stream_event(#{<<"event">> := <<"dist_closed">>}, _State) ->
    exit(connection_closed);
handle_stream_event(_Event, State) ->
    loop(State).

consume_input(Data, #{mode := handshake} = State) ->
    satisfy_waiter(State#{buffer := <<(map_get(buffer, State))/binary, Data/binary>>});
consume_input(Data, #{mode := up} = State) ->
    put_packet4(State#{buffer := <<(map_get(buffer, State))/binary, Data/binary>>}).

satisfy_waiter(#{waiter := undefined} = State) -> State;
satisfy_waiter(#{waiter := {From, Ref, Timer}, buffer := Buffer} = State) ->
    case take_one(2, Buffer) of
        {ok, Packet, Rest} ->
            cancel_timer(Timer),
            reply(From, Ref, {ok, binary_to_list(Packet)}),
            State#{buffer := Rest, waiter := undefined,
                   recv_count := map_get(recv_count, State) + 1};
        more -> State
    end.

take_one(2, <<Size:16, Payload:Size/binary, Rest/binary>>) -> {ok, Payload, Rest};
take_one(4, <<Size:32, Payload:Size/binary, Rest/binary>>) -> {ok, Payload, Rest};
take_one(_, _) -> more.

put_packet4(#{buffer := Buffer, dhandle := DHandle} = State) ->
    {Packets, Rest} = feed(4, <<>>, Buffer),
    lists:foreach(fun(Packet) -> ok = erlang:dist_ctrl_put_data(DHandle, Packet) end, Packets),
    State#{buffer := Rest, recv_count := map_get(recv_count, State) + length(Packets)}.

flush_output(#{mode := handshake} = State) -> State;
flush_output(#{pending_out := Pending} = State) when byte_size(Pending) > 0 ->
    case send_available(Pending, State) of
        {<<>>, State1} -> flush_output(State1#{pending_out := <<>>});
        {Rest, State1} -> State1#{pending_out := Rest}
    end;
flush_output(#{tick_pending := true} = State) ->
    case send_available(<<0:32>>, State) of
        {<<>>, State1} -> flush_output(State1#{tick_pending := false,
                                               send_count := map_get(send_count, State1) + 1});
        {Rest, State1} -> State1#{pending_out := Rest, tick_pending := false}
    end;
flush_output(#{dist_ready := true, dhandle := DHandle} = State) ->
    case erlang:dist_ctrl_get_data(DHandle) of
        none ->
            ok = erlang:dist_ctrl_get_data_notification(DHandle),
            State#{dist_ready := false};
        {Len, Iovec} ->
            Packet = iolist_to_binary([<<Len:32>>, Iovec]),
            State1 = State#{pending_out := Packet,
                            send_count := map_get(send_count, State) + 1},
            flush_output(State1)
    end;
flush_output(State) -> State.

send_available(Data, #{credit := Credit} = State) when Credit > 0 ->
    Size = min(?MAX_PORT_CHUNK, min(Credit, byte_size(Data))),
    <<Chunk:Size/binary, Rest/binary>> = Data,
    case port_call(dist_send, [map_get(stream_id, State), Chunk], State) of
        {ok, _} -> {Rest, State#{credit := Credit - Size}};
        Error -> exit({dist_send, Error})
    end;
send_available(Data, State) -> {Data, State}.

send_bytes(Data, State) when byte_size(Data) =< map_get(credit, State) ->
    case port_call(dist_send, [map_get(stream_id, State), Data], State) of
        {ok, _} -> {ok, State#{credit := map_get(credit, State) - byte_size(Data),
                               send_count := map_get(send_count, State) + 1}};
        Error -> {Error, State}
    end;
send_bytes(_Data, State) -> {{error, no_credit}, State}.

port_call(Function, Args, State) ->
    apply(map_get(port_mod, State), Function, [map_get(port, State) | Args]).

cancel_waiter(Ref, #{waiter := {_From, Ref, Timer}} = State) ->
    cancel_timer(Timer),
    State#{waiter := undefined};
cancel_waiter(_Ref, State) -> State.

timeout_waiter(Ref, #{waiter := {From, Ref, _Timer}} = State) ->
    reply(From, Ref, {error, timeout}),
    State#{waiter := undefined};
timeout_waiter(_Ref, State) -> State.

recv_timer(infinity, _Ref) -> undefined;
recv_timer(Timeout, Ref) -> erlang:send_after(Timeout, self(), {recv_timeout, Ref}).

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    ok.

terminate_stream(State) ->
    catch port_call(dist_close, [map_get(stream_id, State)], State),
    ok.

normalize_exit(normal) -> connection_closed;
normalize_exit(Reason) -> Reason.

call(Pid, Request, Timeout) ->
    Monitor = erlang:monitor(process, Pid),
    Ref = make_ref(),
    Pid ! {call, self(), Ref, Request},
    receive
        {Ref, Reply} ->
            erlang:demonitor(Monitor, [flush]),
            Reply;
        {'DOWN', Monitor, process, Pid, Reason} ->
            exit({dist_controller_exit, Reason})
    after Timeout ->
            Pid ! {cancel_recv, Ref},
            erlang:demonitor(Monitor, [flush]),
            {error, timeout}
    end.

reply(To, Ref, Reply) -> To ! {Ref, Reply}.
