-module(iroh_dist).

-export([listen/1, listen/2, address/0, address/1, accept/1,
         accept_connection/5, setup/5, close/1, select/1, is_node_name/1]).
-export([listener_init/5, accept_loop/3, do_accept/6, do_setup/6]).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist_util.hrl").

-define(PORT, 'Elixir.ElixirRpc.IrohDiscovery').
-define(PORT_MOD, 'Elixir.ElixirRpc.IrohDiscovery.Port').
-define(INITIAL_CREDIT, 256 * 1024).
-define(LISTENER, iroh_dist_listener).

listen(Name) ->
    {ok, Host} = inet:gethostname(),
    listen(Name, Host).

listen(Name, Host) ->
    Node = list_to_atom(atom_to_list(Name) ++ "@" ++ Host),
    Parent = self(),
    Tag = make_ref(),
    Listener = spawn_link(?MODULE, listener_init, [Parent, Tag, Node, Host, port()]),
    receive
        {Tag, ok} -> {ok, {Listener, address(Host), creation()}};
        {Tag, Error} -> Error
    end.

address() ->
    {ok, Host} = inet:gethostname(),
    address(Host).

address(Host) ->
    #net_address{host = Host, protocol = iroh, family = iroh}.

accept(Listener) ->
    spawn_opt(?MODULE, accept_loop, [self(), Listener, port()], [link, {priority, max}]).

accept_connection(AcceptPid, Controller, MyNode, Allowed, SetupTime) ->
    spawn_opt(?MODULE, do_accept,
              [self(), AcceptPid, Controller, MyNode, Allowed, SetupTime],
              dist_util:net_ticker_spawn_options()).

setup(Node, Type, MyNode, _LongOrShortNames, SetupTime) ->
    erlang:display({iroh_dist_setup, Node, MyNode}),
    spawn_opt(?MODULE, do_setup, [self(), Node, Type, MyNode, SetupTime, port()],
              dist_util:net_ticker_spawn_options()).

close(Listener) when is_pid(Listener) ->
    Ref = make_ref(),
    Listener ! {close, self(), Ref},
    receive {Ref, ok} -> ok end.

select(Node) ->
    Result = is_node_name(Node),
    erlang:display({iroh_dist_select, Node, Result}),
    Result.

is_node_name(Node) when is_atom(Node) ->
    valid_node_binary(unicode:characters_to_binary(atom_to_list(Node)));
is_node_name(_) -> false.

listener_init(Parent, Tag, Node, _Host, Port) ->
    true = register(?LISTENER, self()),
    ok = ?PORT_MOD:subscribe(Port, self()),
    case ?PORT_MOD:dist_listen(Port, node_binary(Node)) of
        {ok, _} ->
            Parent ! {Tag, ok},
            listener_loop(Port, undefined, queue:new(), #{}, #{});
        Error ->
            Parent ! {Tag, Error}
    end.

listener_loop(Port, Acceptor, Incoming, Controllers, Pending) ->
    receive
        {acceptor, Pid} ->
            dispatch_incoming(Port, Pid, Incoming, Controllers, Pending);
        {bind, StreamId, Controller, From, Ref} ->
            erlang:monitor(process, Controller),
            Events = maps:get(StreamId, Pending, []),
            lists:foreach(fun(Event) -> Controller ! {iroh_dist, Event} end,
                          lists:reverse(Events)),
            From ! {Ref, ok},
            listener_loop(Port, Acceptor, Incoming,
                          Controllers#{StreamId => Controller},
                           maps:remove(StreamId, Pending));
        {'DOWN', _Monitor, process, Controller, _Reason} ->
            Remaining = maps:filter(fun(_StreamId, Pid) -> Pid =/= Controller end,
                                    Controllers),
            listener_loop(Port, Acceptor, Incoming, Remaining, Pending);
        {iroh_dist, #{<<"event">> := <<"dist_incoming">>} = Event} ->
            case Acceptor of
                undefined ->
                    listener_loop(Port, Acceptor, queue:in(Event, Incoming), Controllers, Pending);
                _ ->
                    Acceptor ! {incoming, Event},
                    listener_loop(Port, Acceptor, Incoming, Controllers, Pending)
            end;
        {iroh_dist, #{<<"stream_id">> := StreamId} = Event} ->
            case maps:find(StreamId, Controllers) of
                {ok, Controller} ->
                    Controller ! {iroh_dist, Event},
                    listener_loop(Port, Acceptor, Incoming, Controllers, Pending);
                error ->
                    Events = maps:get(StreamId, Pending, []),
                    listener_loop(Port, Acceptor, Incoming, Controllers,
                                  Pending#{StreamId => [Event | Events]})
            end;
        {close, From, Ref} ->
            ?PORT_MOD:unsubscribe(Port, self()),
            unregister(?LISTENER),
            case Acceptor of undefined -> ok; _ -> Acceptor ! listener_closed end,
            From ! {Ref, ok};
        _Other ->
            listener_loop(Port, Acceptor, Incoming, Controllers, Pending)
    end.

dispatch_incoming(Port, Acceptor, Incoming, Controllers, Pending) ->
    case queue:out(Incoming) of
        {{value, Event}, Rest} ->
            Acceptor ! {incoming, Event},
            listener_loop(Port, Acceptor, Rest, Controllers, Pending);
        {empty, _} ->
            listener_loop(Port, Acceptor, Incoming, Controllers, Pending)
    end.

accept_loop(Kernel, Listener, Port) ->
    Listener ! {acceptor, self()},
    receive
        {incoming, #{<<"stream_id">> := StreamId}} ->
            {ok, Controller} =
                iroh_dist_controller:start(?PORT_MOD, Port, StreamId, ?INITIAL_CREDIT, false),
            Ref = make_ref(),
            Listener ! {bind, StreamId, Controller, self(), Ref},
            receive {Ref, ok} -> ok end,
            Kernel ! {accept, self(), Controller, iroh, iroh},
            receive
                {Kernel, controller, Supervisor} ->
                    ok = iroh_dist_controller:supervisor(Controller, Supervisor),
                    Supervisor ! {self(), controller};
                {Kernel, unsupported_protocol} ->
                    iroh_dist_controller:close(Controller),
                    exit(unsupported_protocol)
            end,
            accept_loop(Kernel, Listener, Port);
        listener_closed ->
            exit(normal)
    end.

do_accept(Kernel, AcceptPid, Controller, MyNode, Allowed, SetupTime) ->
    receive
        {AcceptPid, controller} ->
            Timer = dist_util:start_timer(SetupTime),
            HSData = (hs_data(Controller))#hs_data{kernel_pid = Kernel,
                                                   this_node = MyNode,
                                                   timer = Timer,
                                                   this_flags = 0,
                                                   allowed = Allowed},
            dist_util:handshake_other_started(HSData)
    end.

do_setup(Kernel, Node, Type, MyNode, SetupTime, Port) ->
    Timer = dist_util:start_timer(SetupTime),
    case ?PORT_MOD:dist_connect(Port, node_binary(MyNode), node_binary(Node), SetupTime) of
        {ok, #{<<"stream_id">> := StreamId}} ->
            dist_util:reset_timer(Timer),
            {ok, Controller} =
                iroh_dist_controller:start(?PORT_MOD, Port, StreamId, ?INITIAL_CREDIT, false),
            ok = iroh_dist_controller:supervisor(Controller, self()),
            ok = bind_controller(StreamId, Controller),
            HSData = (hs_data(Controller))#hs_data{kernel_pid = Kernel,
                                                   other_node = Node,
                                                   this_node = MyNode,
                                                   timer = Timer,
                                                   this_flags = 0,
                                                   other_version = 6,
                                                   request_type = Type},
            dist_util:handshake_we_started(HSData);
        _Error ->
            erlang:display({iroh_dist_setup_error, Node, _Error}),
            exit({shutdown, Node})
    end.

hs_data(Controller) ->
    #hs_data{socket = Controller,
             f_send = fun iroh_dist_controller:send/2,
             f_recv = fun iroh_dist_controller:recv/3,
             f_setopts_pre_nodeup = fun(_C) -> ok end,
             f_setopts_post_nodeup = fun(_C) -> ok end,
             f_getll = fun(C) -> {ok, C} end,
             f_address = fun(_C, Node) -> remote_address(Node) end,
             f_handshake_complete =
                 fun(C, _Node, DHandle) ->
                         iroh_dist_controller:handshake_complete(C, DHandle)
                 end,
             mf_tick = fun iroh_dist_controller:tick/1,
             mf_getstat = fun iroh_dist_controller:getstat/1}.

remote_address(Node) ->
    [_Name, Host] = string:split(atom_to_list(Node), "@", all),
    (address(Host))#net_address{address = node_binary(Node)}.

node_binary(Node) -> unicode:characters_to_binary(atom_to_list(Node)).

bind_controller(StreamId, Controller) ->
    case whereis(?LISTENER) of
        undefined -> {error, no_listener};
        Listener ->
            Ref = make_ref(),
            Listener ! {bind, StreamId, Controller, self(), Ref},
            receive {Ref, Result} -> Result end
    end.

valid_node_binary(Node) when byte_size(Node) =< 255 ->
    case binary:split(Node, <<"@">>, [global]) of
        [Name, Host] when byte_size(Name) > 0, byte_size(Host) > 0 -> true;
        _ -> false
    end;
valid_node_binary(_) -> false.

creation() ->
    case binary:decode_unsigned(crypto:strong_rand_bytes(4)) of
        Value when Value < 4 -> creation();
        Value -> Value
    end.

port() -> ?PORT.
