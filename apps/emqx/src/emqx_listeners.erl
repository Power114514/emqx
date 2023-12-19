%%--------------------------------------------------------------------
%% Copyright (c) 2018-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc Start/Stop MQTT listeners.
-module(emqx_listeners).

-include("emqx_mqtt.hrl").
-include("emqx_schema.hrl").
-include("logger.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%% APIs
-export([
    list_raw/0,
    list/0,
    start/0,
    restart/0,
    stop/0,
    is_running/1,
    current_conns/2,
    max_conns/2,
    id_example/0,
    default_max_conn/0,
    shutdown_count/2
]).

-export([
    start_listener/1,
    start_listener/3,
    stop_listener/1,
    stop_listener/3,
    restart_listener/1,
    restart_listener/3,
    has_enabled_listener_conf_by_type/1
]).

-export([
    listener_id/2,
    parse_listener_id/1,
    ensure_override_limiter_conf/2,
    esockd_access_rules/1
]).

-export([pre_config_update/3, post_config_update/5]).

-export([format_bind/1]).

-ifdef(TEST).
-export([certs_dir/2]).
-endif.

-export_type([listener_id/0]).

-type listener_id() :: atom() | binary().
-type listener_type() :: tcp | ssl | ws | wss | quic | dtls.

-define(ESOCKD_LISTENER(T), (T == tcp orelse T == ssl)).
-define(COWBOY_LISTENER(T), (T == ws orelse T == wss)).

-define(ROOT_KEY, listeners).
-define(CONF_KEY_PATH, [?ROOT_KEY, '?', '?']).
-define(TYPES_STRING, ["tcp", "ssl", "ws", "wss", "quic"]).
-define(MARK_DEL, ?TOMBSTONE_CONFIG_CHANGE_REQ).

-spec id_example() -> atom().
id_example() -> 'tcp:default'.

%% @doc List configured listeners.
-spec list_raw() -> [{ListenerId :: atom(), Type :: binary(), ListenerConf :: map()}].
list_raw() ->
    [
        {listener_id(Type, LName), Type, LConf}
     || {Type, LName, LConf} <- do_list_raw()
    ].

list() ->
    Listeners = maps:to_list(emqx:get_config([listeners], #{})),
    lists:flatmap(fun format_list/1, Listeners).

format_list(Listener) ->
    {Type, Conf} = Listener,
    [
        begin
            Running = is_running(Type, listener_id(Type, LName), LConf),
            {listener_id(Type, LName), maps:put(running, Running, LConf)}
        end
     || {LName, LConf} <- maps:to_list(Conf), is_map(LConf)
    ].

do_list_raw() ->
    %% GET /listeners from other nodes returns [] when init config is not loaded.
    %% FIXME This is a workaround for the issue:
    %% mria:running_nodes() sometime return node which not ready to accept rpc call.
    case emqx_app:init_load_done() of
        true ->
            Key = <<"listeners">>,
            Raw = emqx_config:get_raw([Key], #{}),
            SchemaMod = emqx_config:get_schema_mod(Key),
            #{Key := RawWithDefault} = emqx_config:fill_defaults(SchemaMod, #{Key => Raw}, #{}),
            Listeners = maps:to_list(RawWithDefault),
            lists:flatmap(fun format_raw_listeners/1, Listeners);
        false ->
            []
    end.

format_raw_listeners({Type0, Conf}) ->
    Type = binary_to_atom(Type0),
    lists:filtermap(
        fun
            ({LName, LConf0}) when is_map(LConf0) ->
                Bind = parse_bind(LConf0),
                MaxConn = maps:get(<<"max_connections">>, LConf0, default_max_conn()),
                Running = is_running(Type, listener_id(Type, LName), LConf0#{bind => Bind}),
                LConf1 = maps:without([<<"authentication">>, <<"zone">>], LConf0),
                LConf2 = maps:put(<<"running">>, Running, LConf1),
                CurrConn =
                    case Running of
                        true -> current_conns(Type, LName, Bind);
                        false -> 0
                    end,
                LConf = maps:merge(LConf2, #{
                    <<"current_connections">> => CurrConn,
                    <<"max_connections">> => ensure_max_conns(MaxConn)
                }),
                {true, {Type0, LName, LConf}};
            ({_LName, _MarkDel}) ->
                false
        end,
        maps:to_list(Conf)
    ).

-spec is_running(ListenerId :: atom()) -> boolean() | {error, not_found}.
is_running(ListenerId) ->
    case lists:keyfind(ListenerId, 1, list()) of
        {_Id, #{running := Running}} -> Running;
        false -> {error, not_found}
    end.

is_running(Type, ListenerId, Conf) when Type =:= tcp; Type =:= ssl ->
    #{bind := ListenOn} = Conf,
    try esockd:listener({ListenerId, ListenOn}) of
        Pid when is_pid(Pid) ->
            true
    catch
        _:_ ->
            false
    end;
is_running(Type, ListenerId, _Conf) when Type =:= ws; Type =:= wss ->
    try
        Info = ranch:info(ListenerId),
        proplists:get_value(status, Info) =:= running
    catch
        _:_ ->
            false
    end;
is_running(quic, ListenerId, _Conf) ->
    case quicer:listener(ListenerId) of
        {ok, Pid} when is_pid(Pid) ->
            true;
        _ ->
            false
    end.

current_conns(ID, ListenOn) ->
    {ok, #{type := Type, name := Name}} = parse_listener_id(ID),
    current_conns(Type, Name, ListenOn).

current_conns(Type, Name, ListenOn) when Type == tcp; Type == ssl ->
    esockd:get_current_connections({listener_id(Type, Name), ListenOn});
current_conns(Type, Name, _ListenOn) when Type =:= ws; Type =:= wss ->
    proplists:get_value(all_connections, ranch:info(listener_id(Type, Name)));
current_conns(quic, _Name, _ListenOn) ->
    case quicer:perf_counters() of
        {ok, PerfCnts} -> proplists:get_value(conn_active, PerfCnts);
        _ -> 0
    end;
current_conns(_, _, _) ->
    {error, not_support}.

max_conns(ID, ListenOn) ->
    {ok, #{type := Type, name := Name}} = parse_listener_id(ID),
    max_conns(Type, Name, ListenOn).

max_conns(Type, Name, ListenOn) when Type == tcp; Type == ssl ->
    esockd:get_max_connections({listener_id(Type, Name), ListenOn});
max_conns(Type, Name, _ListenOn) when Type =:= ws; Type =:= wss ->
    proplists:get_value(max_connections, ranch:info(listener_id(Type, Name)));
max_conns(_, _, _) ->
    {error, not_support}.

shutdown_count(ID, ListenOn) ->
    {ok, #{type := Type, name := Name}} = parse_listener_id(ID),
    shutdown_count(Type, Name, ListenOn).

shutdown_count(Type, Name, ListenOn) when Type == tcp; Type == ssl ->
    esockd:get_shutdown_count({listener_id(Type, Name), ListenOn});
shutdown_count(Type, _Name, _ListenOn) when Type =:= ws; Type =:= wss ->
    [];
shutdown_count(_, _, _) ->
    {error, not_support}.

%% @doc Start all listeners.
-spec start() -> ok.
start() ->
    %% The ?MODULE:start/0 will be called by emqx_app when emqx get started,
    %% so we install the config handler here.
    %% callback when http api request
    ok = emqx_config_handler:add_handler(?CONF_KEY_PATH, ?MODULE),
    %% callback when reload from config file
    ok = emqx_config_handler:add_handler([?ROOT_KEY], ?MODULE),
    foreach_listeners(fun start_listener/3).

-spec start_listener(listener_id()) -> ok | {error, term()}.
start_listener(ListenerId) ->
    apply_on_listener(ListenerId, fun start_listener/3).

-spec start_listener(listener_type(), atom(), map()) -> ok | {error, term()}.
start_listener(Type, ListenerName, #{bind := Bind, enable := true} = Conf) ->
    case do_start_listener(Type, ListenerName, Conf) of
        {ok, {skipped, Reason}} when
            Reason =:= quic_app_missing
        ->
            ?tp(listener_not_started, #{type => Type, bind => Bind, status => {skipped, Reason}}),
            console_print(
                "Listener ~ts is NOT started due to: ~p.~n",
                [listener_id(Type, ListenerName), Reason]
            ),
            ok;
        {ok, _} ->
            ?tp(listener_started, #{type => Type, bind => Bind}),
            console_print(
                "Listener ~ts on ~ts started.~n",
                [listener_id(Type, ListenerName), format_bind(Bind)]
            ),
            ok;
        {error, {already_started, Pid}} ->
            ?tp(listener_not_started, #{
                type => Type, bind => Bind, status => {already_started, Pid}
            }),
            {error, {already_started, Pid}};
        {error, Reason} ->
            ?tp(listener_not_started, #{type => Type, bind => Bind, status => {error, Reason}}),
            ListenerId = listener_id(Type, ListenerName),
            BindStr = format_bind(Bind),
            ?ELOG(
                "Failed to start listener ~ts on ~ts: ~0p.~n",
                [ListenerId, BindStr, Reason]
            ),
            Msg = lists:flatten(
                io_lib:format(
                    "~ts(~ts) : ~p",
                    [ListenerId, BindStr, filter_stacktrace(Reason)]
                )
            ),
            {error, {failed_to_start, Msg}}
    end;
start_listener(Type, ListenerName, #{enable := false}) ->
    console_print(
        "Listener ~ts is NOT started due to: disabled.~n",
        [listener_id(Type, ListenerName)]
    ),
    ok.

%% @doc Restart all listeners
-spec restart() -> ok.
restart() ->
    foreach_listeners(fun restart_listener/3).

-spec restart_listener(listener_id()) -> ok | {error, term()}.
restart_listener(ListenerId) ->
    apply_on_listener(ListenerId, fun restart_listener/3).

-spec restart_listener(listener_type(), atom(), map()) -> ok | {error, term()}.
restart_listener(Type, ListenerName, Conf) ->
    restart_listener(Type, ListenerName, Conf, Conf).

update_listener(_Type, _Name, #{enable := false}, #{enable := false}) ->
    ok;
update_listener(Type, Name, Conf = #{enable := true}, #{enable := false}) ->
    stop_listener(Type, Name, Conf);
update_listener(Type, Name, #{enable := false}, Conf = #{enable := true}) ->
    start_listener(Type, Name, Conf);
update_listener(Type, Name, OldConf = #{bind := Bind}, NewConf = #{bind := Bind}) ->
    case do_update_listener(Type, Name, OldConf, NewConf) of
        ok ->
            ok = maybe_unregister_ocsp_stapling_refresh(Type, Name, NewConf),
            ok;
        {error, _Reason} ->
            restart_listener(Type, Name, OldConf, NewConf)
    end;
update_listener(Type, Name, OldConf, NewConf) ->
    %% TODO
    %% Again, we're not strictly required to drop live connections in this case.
    restart_listener(Type, Name, OldConf, NewConf).

restart_listener(Type, Name, OldConf, NewConf) ->
    case stop_listener(Type, Name, OldConf) of
        ok ->
            start_listener(Type, Name, NewConf);
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Stop all listeners.
-spec stop() -> ok.
stop() ->
    %% The ?MODULE:stop/0 will be called by emqx_app when emqx is going to shutdown,
    %% so we uninstall the config handler here.
    ok = emqx_config_handler:remove_handler(?CONF_KEY_PATH),
    ok = emqx_config_handler:remove_handler([?ROOT_KEY]),
    foreach_listeners(fun stop_listener/3).

-spec stop_listener(listener_id()) -> ok | {error, term()}.
stop_listener(ListenerId) ->
    apply_on_listener(ListenerId, fun stop_listener/3).

stop_listener(Type, Name, #{bind := Bind} = Conf) ->
    Id = listener_id(Type, Name),
    ok = del_limiter_bucket(Id, Conf),
    ok = unregister_ocsp_stapling_refresh(Type, Name),
    case do_stop_listener(Type, Id, Conf) of
        ok ->
            console_print(
                "Listener ~ts on ~ts stopped.~n",
                [Id, format_bind(Bind)]
            ),
            ok;
        {error, not_found} ->
            ok;
        {error, Reason} ->
            ?ELOG(
                "Failed to stop listener ~ts on ~ts: ~0p~n",
                [Id, format_bind(Bind), Reason]
            ),
            {error, Reason}
    end.

-spec do_stop_listener(listener_type(), atom(), map()) -> ok | {error, term()}.
do_stop_listener(Type, Id, #{bind := ListenOn}) when ?ESOCKD_LISTENER(Type) ->
    esockd:close(Id, ListenOn);
do_stop_listener(Type, Id, #{bind := ListenOn}) when ?COWBOY_LISTENER(Type) ->
    case cowboy:stop_listener(Id) of
        ok ->
            wait_listener_stopped(ListenOn);
        Error ->
            Error
    end;
do_stop_listener(quic, Id, _Conf) ->
    quicer:terminate_listener(Id).

wait_listener_stopped(ListenOn) ->
    % NOTE
    % `cowboy:stop_listener/1` will not close the listening socket explicitly,
    % it will be closed by the runtime system **only after** the process exits.
    Endpoint = maps:from_list(ip_port(ListenOn)),
    case
        gen_tcp:connect(
            maps:get(ip, Endpoint, loopback),
            maps:get(port, Endpoint),
            [{active, false}]
        )
    of
        {error, _EConnrefused} ->
            %% NOTE
            %% We should get `econnrefused` here because acceptors are already dead
            %% but don't want to crash if not, because this doesn't make any difference.
            ok;
        {ok, Socket} ->
            %% NOTE
            %% Tiny chance to get a connected socket here, when some other process
            %% concurrently binds to the same port.
            gen_tcp:close(Socket)
    end.

-ifndef(TEST).
console_print(Fmt, Args) -> ?ULOG(Fmt, Args).
-else.
console_print(_Fmt, _Args) -> ok.
-endif.

-spec do_start_listener(listener_type(), atom(), map()) ->
    {ok, pid() | {skipped, atom()}} | {error, term()}.
%% Start MQTT/TCP listener
do_start_listener(Type, Name, #{bind := ListenOn} = Opts) when ?ESOCKD_LISTENER(Type) ->
    Id = listener_id(Type, Name),
    ok = add_limiter_bucket(Id, limiter(Opts)),
    esockd:open(
        Id,
        ListenOn,
        merge_default(esockd_opts(Id, Type, Name, Opts))
    );
%% Start MQTT/WS listener
do_start_listener(Type, ListenerName, #{bind := ListenOn} = Opts) when ?COWBOY_LISTENER(Type) ->
    Id = listener_id(Type, ListenerName),
    ok = add_limiter_bucket(Id, limiter(Opts)),
    RanchOpts = ranch_opts(Type, ListenOn, Opts),
    WsOpts = ws_opts(Type, ListenerName, Opts),
    case Type of
        ws -> cowboy:start_clear(Id, RanchOpts, WsOpts);
        wss -> cowboy:start_tls(Id, RanchOpts, WsOpts)
    end;
%% Start MQTT/QUIC listener
do_start_listener(quic, ListenerName, #{bind := Bind} = Opts) ->
    ListenOn =
        case Bind of
            {Addr, Port} when tuple_size(Addr) == 4 ->
                %% IPv4
                lists:flatten(io_lib:format("~ts:~w", [inet:ntoa(Addr), Port]));
            {Addr, Port} when tuple_size(Addr) == 8 ->
                %% IPv6
                lists:flatten(io_lib:format("[~ts]:~w", [inet:ntoa(Addr), Port]));
            Port ->
                Port
        end,

    case [A || {quicer, _, _} = A <- application:which_applications()] of
        [_] ->
            DefAcceptors = erlang:system_info(schedulers_online) * 8,
            SSLOpts = maps:get(ssl_options, Opts, #{}),
            ListenOpts =
                [
                    {certfile, emqx_schema:naive_env_interpolation(maps:get(certfile, SSLOpts))},
                    {keyfile, emqx_schema:naive_env_interpolation(maps:get(keyfile, SSLOpts))},
                    {alpn, ["mqtt"]},
                    {conn_acceptors, lists:max([DefAcceptors, maps:get(acceptors, Opts, 0)])},
                    {keep_alive_interval_ms, maps:get(keep_alive_interval, Opts, 0)},
                    {idle_timeout_ms, maps:get(idle_timeout, Opts, 0)},
                    {handshake_idle_timeout_ms, maps:get(handshake_idle_timeout, Opts, 10000)},
                    {server_resumption_level, maps:get(server_resumption_level, Opts, 2)},
                    {verify, maps:get(verify, SSLOpts, verify_none)}
                ] ++
                    case maps:get(cacertfile, SSLOpts, undefined) of
                        undefined ->
                            [];
                        <<>> ->
                            [];
                        "" ->
                            [];
                        CaCertFile ->
                            [{cacertfile, emqx_schema:naive_env_interpolation(CaCertFile)}]
                    end ++
                    case maps:get(password, SSLOpts, undefined) of
                        undefined -> [];
                        Password -> [{password, str(Password)}]
                    end ++
                    optional_quic_listener_opts(Opts),
            Limiter = limiter(Opts),
            ConnectionOpts = #{
                conn_callback => emqx_quic_connection,
                peer_unidi_stream_count => maps:get(peer_unidi_stream_count, Opts, 1),
                peer_bidi_stream_count => maps:get(peer_bidi_stream_count, Opts, 10),
                zone => zone(Opts),
                listener => {quic, ListenerName},
                limiter => Limiter
            },
            StreamOpts = #{
                stream_callback => emqx_quic_stream,
                active => 1
            },

            Id = listener_id(quic, ListenerName),
            add_limiter_bucket(Id, Limiter),
            quicer:spawn_listener(
                Id,
                ListenOn,
                {maps:from_list(ListenOpts), ConnectionOpts, StreamOpts}
            );
        [] ->
            {ok, {skipped, quic_app_missing}}
    end.

do_update_listener(Type, Name, _OldConf, NewConf) when ?ESOCKD_LISTENER(Type) ->
    Id = listener_id(Type, Name),
    ListenOn = maps:get(bind, NewConf),
    esockd:set_options({Id, ListenOn}, esockd_opts(Id, Type, Name, NewConf));
do_update_listener(_Type, _Name, _OldConf, _NewConf) ->
    {error, not_supported}.

%% Update the listeners at runtime
pre_config_update([?ROOT_KEY, Type, Name], {create, NewConf}, V) when
    V =:= undefined orelse V =:= ?TOMBSTONE_VALUE
->
    {ok, convert_certs(Type, Name, NewConf)};
pre_config_update([?ROOT_KEY, _Type, _Name], {create, _NewConf}, _RawConf) ->
    {error, already_exist};
pre_config_update([?ROOT_KEY, _Type, _Name], {update, _Request}, undefined) ->
    {error, not_found};
pre_config_update([?ROOT_KEY, Type, Name], {update, Request}, RawConf) ->
    RawConf1 = emqx_utils_maps:deep_merge(RawConf, Request),
    RawConf2 = ensure_override_limiter_conf(RawConf1, Request),
    {ok, convert_certs(Type, Name, RawConf2)};
pre_config_update([?ROOT_KEY, _Type, _Name], {action, _Action, Updated}, RawConf) ->
    {ok, emqx_utils_maps:deep_merge(RawConf, Updated)};
pre_config_update([?ROOT_KEY, _Type, _Name], ?MARK_DEL, _RawConf) ->
    {ok, ?TOMBSTONE_VALUE};
pre_config_update([?ROOT_KEY], RawConf, RawConf) ->
    {ok, RawConf};
pre_config_update([?ROOT_KEY], NewConf, _RawConf) ->
    {ok, convert_certs(NewConf)}.

post_config_update([?ROOT_KEY, Type, Name], {create, _Request}, NewConf, OldConf, _AppEnvs) when
    OldConf =:= undefined orelse OldConf =:= ?TOMBSTONE_TYPE
->
    start_listener(Type, Name, NewConf);
post_config_update([?ROOT_KEY, Type, Name], {update, _Request}, NewConf, OldConf, _AppEnvs) ->
    update_listener(Type, Name, OldConf, NewConf);
post_config_update([?ROOT_KEY, Type, Name], ?MARK_DEL, _, OldConf = #{}, _AppEnvs) ->
    stop_listener(Type, Name, OldConf);
post_config_update([?ROOT_KEY, Type, Name], {action, _Action, _}, NewConf, OldConf, _AppEnvs) ->
    update_listener(Type, Name, OldConf, NewConf);
post_config_update([?ROOT_KEY], _Request, OldConf, OldConf, _AppEnvs) ->
    ok;
post_config_update([?ROOT_KEY], _Request, NewConf, OldConf, _AppEnvs) ->
    #{added := Added, removed := Removed, changed := Changed} = diff_confs(NewConf, OldConf),
    %% TODO
    %% This currently lacks transactional semantics. If one of the changes fails,
    %% previous changes will not be rolled back.
    perform_listener_changes(
        [{update, L} || L <- Changed] ++
            [{stop, L} || L <- Removed] ++
            [{start, L} || L <- Added]
    );
post_config_update(_Path, _Request, _NewConf, _OldConf, _AppEnvs) ->
    ok.

perform_listener_changes([]) ->
    ok;
perform_listener_changes([{Action, Listener} | Rest]) ->
    case perform_listener_change(Action, Listener) of
        ok -> perform_listener_changes(Rest);
        {error, Reason} -> {error, Reason}
    end.

perform_listener_change(start, {Type, Name, Conf}) ->
    start_listener(Type, Name, Conf);
perform_listener_change(update, {{Type, Name, ConfOld}, {_, _, ConfNew}}) ->
    update_listener(Type, Name, ConfOld, ConfNew);
perform_listener_change(stop, {Type, Name, Conf}) ->
    stop_listener(Type, Name, Conf).

esockd_opts(ListenerId, Type, Name, Opts0) ->
    Opts1 = maps:with([acceptors, max_connections, proxy_protocol, proxy_protocol_timeout], Opts0),
    Limiter = limiter(Opts0),
    Opts2 =
        case emqx_limiter_utils:extract_with_type(connection, Limiter) of
            undefined ->
                Opts1;
            BucketCfg ->
                Opts1#{
                    limiter => emqx_esockd_htb_limiter:new_create_options(
                        ListenerId, connection, BucketCfg
                    )
                }
        end,
    Opts3 = Opts2#{
        access_rules => esockd_access_rules(maps:get(access_rules, Opts0, [])),
        tune_fun => {emqx_olp, backoff_new_conn, [zone(Opts0)]},
        connection_mfargs =>
            {emqx_connection, start_link, [
                #{
                    listener => {Type, Name},
                    zone => zone(Opts0),
                    limiter => Limiter,
                    enable_authn => enable_authn(Opts0)
                }
            ]}
    },
    maps:to_list(
        case Type of
            tcp ->
                Opts3#{tcp_options => tcp_opts(Opts0)};
            ssl ->
                OptsWithCRL = inject_crl_config(Opts0),
                OptsWithSNI = inject_sni_fun(ListenerId, OptsWithCRL),
                SSLOpts = ssl_opts(OptsWithSNI),
                Opts3#{ssl_options => SSLOpts, tcp_options => tcp_opts(Opts0)}
        end
    ).

ws_opts(Type, ListenerName, Opts) ->
    WsPaths = [
        {emqx_utils_maps:deep_get([websocket, mqtt_path], Opts, "/mqtt"), emqx_ws_connection, #{
            zone => zone(Opts),
            listener => {Type, ListenerName},
            limiter => limiter(Opts),
            enable_authn => enable_authn(Opts)
        }}
    ],
    Dispatch = cowboy_router:compile([{'_', WsPaths}]),
    ProxyProto = maps:get(proxy_protocol, Opts, false),
    #{env => #{dispatch => Dispatch}, proxy_header => ProxyProto}.

ranch_opts(Type, ListenOn, Opts) ->
    NumAcceptors = maps:get(acceptors, Opts, 4),
    MaxConnections = maps:get(max_connections, Opts, 1024),
    SocketOpts =
        case Type of
            wss -> tcp_opts(Opts) ++ proplists:delete(handshake_timeout, ssl_opts(Opts));
            ws -> tcp_opts(Opts)
        end,
    #{
        num_acceptors => NumAcceptors,
        max_connections => MaxConnections,
        handshake_timeout => maps:get(handshake_timeout, Opts, 15000),
        socket_opts => ip_port(ListenOn) ++
            %% cowboy don't allow us to set 'reuseaddr'
            proplists:delete(reuseaddr, SocketOpts)
    }.

ip_port(Port) when is_integer(Port) ->
    [{port, Port}];
ip_port({Addr, Port}) ->
    [{ip, Addr}, {port, Port}].

esockd_access_rules(StrRules) ->
    Access = fun(S, Acc) ->
        [A, CIDR] = string:tokens(S, " "),
        %% esockd rules only use words 'allow' and 'deny', both are existing
        %% comparison of strings may be better, but there is a loss of backward compatibility
        case emqx_utils:safe_to_existing_atom(A) of
            {ok, Action} ->
                [
                    {
                        Action,
                        case CIDR of
                            "all" -> all;
                            _ -> CIDR
                        end
                    }
                    | Acc
                ];
            _ ->
                ?SLOG(warning, #{msg => "invalid_esockd_access_rule", rule => S}),
                Acc
        end
    end,
    lists:foldr(Access, [], StrRules).

merge_default(Options) ->
    case lists:keytake(tcp_options, 1, Options) of
        {value, {tcp_options, TcpOpts}, Options1} ->
            [{tcp_options, emqx_utils:merge_opts(?MQTT_SOCKOPTS, TcpOpts)} | Options1];
        false ->
            [{tcp_options, ?MQTT_SOCKOPTS} | Options]
    end.

-spec format_bind(
    integer() | {tuple(), integer()} | string() | binary()
) -> io_lib:chars().
format_bind(Port) when is_integer(Port) ->
    %% **Note**:
    %% 'For TCP, UDP and IP networks, if the host is empty or a literal
    %% unspecified IP address, as in ":80", "0.0.0.0:80" or "[::]:80" for
    %% TCP and UDP, "", "0.0.0.0" or "::" for IP, the local system is
    %% assumed.'
    %%
    %% Quoted from: https://pkg.go.dev/net
    %% Decided to use this format to display the bind for all interfaces and
    %% IPv4/IPv6 support
    io_lib:format(":~w", [Port]);
format_bind({Addr, Port}) when is_list(Addr) ->
    io_lib:format("~ts:~w", [Addr, Port]);
format_bind({Addr, Port}) when is_tuple(Addr), tuple_size(Addr) == 4 ->
    io_lib:format("~ts:~w", [inet:ntoa(Addr), Port]);
format_bind({Addr, Port}) when is_tuple(Addr), tuple_size(Addr) == 8 ->
    io_lib:format("[~ts]:~w", [inet:ntoa(Addr), Port]);
%% Support string, binary type for Port or IP:Port
format_bind(Str) when is_list(Str) ->
    case emqx_schema:to_ip_port(Str) of
        {ok, {Ip, Port}} ->
            format_bind({Ip, Port});
        {ok, Port} ->
            format_bind(Port);
        {error, _} ->
            format_bind(list_to_integer(Str))
    end;
format_bind(Bin) when is_binary(Bin) ->
    format_bind(binary_to_list(Bin)).

listener_id(Type, ListenerName) ->
    list_to_atom(lists:append([str(Type), ":", str(ListenerName)])).

-spec parse_listener_id(listener_id()) -> {ok, #{type => atom(), name => atom()}} | {error, term()}.
parse_listener_id(Id) ->
    case string:split(str(Id), ":", leading) of
        [Type, Name] ->
            case lists:member(Type, ?TYPES_STRING) of
                true -> {ok, #{type => list_to_existing_atom(Type), name => list_to_atom(Name)}};
                false -> {error, {invalid_listener_id, Id}}
            end;
        _ ->
            {error, {invalid_listener_id, Id}}
    end.

zone(Opts) ->
    maps:get(zone, Opts, undefined).

limiter(Opts) ->
    emqx_limiter_utils:get_listener_opts(Opts).

add_limiter_bucket(_Id, undefined) ->
    ok;
add_limiter_bucket(Id, Limiter) ->
    maps:fold(
        fun(Type, Cfg, _) ->
            emqx_limiter_server:add_bucket(Id, Type, Cfg)
        end,
        ok,
        maps:without([client], Limiter)
    ).

del_limiter_bucket(Id, Conf) ->
    case limiter(Conf) of
        undefined ->
            ok;
        Limiter ->
            lists:foreach(
                fun(Type) ->
                    emqx_limiter_server:del_bucket(Id, Type)
                end,
                maps:keys(Limiter)
            )
    end.

diff_confs(NewConfs, OldConfs) ->
    emqx_utils:diff_lists(
        flatten_confs(NewConfs),
        flatten_confs(OldConfs),
        fun({Type, Name, _}) -> {Type, Name} end
    ).

flatten_confs(Confs) ->
    lists:flatmap(
        fun({Type, Listeners}) ->
            do_flatten_confs(Type, Listeners)
        end,
        maps:to_list(Confs)
    ).

do_flatten_confs(Type, Listeners) ->
    FilterFun =
        fun
            ({_Name, ?TOMBSTONE_TYPE}) -> false;
            ({Name, Conf}) -> {true, {Type, Name, Conf}}
        end,
    lists:filtermap(FilterFun, maps:to_list(Listeners)).

enable_authn(Opts) ->
    maps:get(enable_authn, Opts, true).

ssl_opts(Opts) ->
    emqx_tls_lib:to_server_opts(tls, maps:get(ssl_options, Opts, #{})).

tcp_opts(Opts) ->
    maps:to_list(
        maps:without(
            [active_n, keepalive],
            maps:get(tcp_options, Opts, #{})
        )
    ).

foreach_listeners(Do) ->
    lists:foreach(
        fun({Id, LConf}) ->
            {ok, #{type := Type, name := Name}} = parse_listener_id(Id),
            case Do(Type, Name, LConf) of
                {error, {failed_to_start, _} = Reason} -> error(Reason);
                {error, {already_started, _}} -> ok;
                ok -> ok
            end
        end,
        list()
    ).

has_enabled_listener_conf_by_type(Type) ->
    lists:any(
        fun({Id, LConf}) when is_map(LConf) ->
            {ok, #{type := Type0}} = parse_listener_id(Id),
            Type =:= Type0 andalso maps:get(enable, LConf, true)
        end,
        list()
    ).

apply_on_listener(ListenerId, Do) ->
    {ok, #{type := Type, name := Name}} = parse_listener_id(ListenerId),
    case emqx_config:find_listener_conf(Type, Name, []) of
        {not_found, _, _} -> error({listener_config_not_found, Type, Name});
        {ok, Conf} -> Do(Type, Name, Conf)
    end.

str(A) when is_atom(A) ->
    atom_to_list(A);
str(B) when is_binary(B) ->
    binary_to_list(B);
str(S) when is_list(S) ->
    S.

parse_bind(#{<<"bind">> := Bind}) when is_integer(Bind) -> Bind;
parse_bind(#{<<"bind">> := Bind}) ->
    case emqx_schema:to_ip_port(binary_to_list(Bind)) of
        {ok, L} -> L;
        {error, _} -> binary_to_integer(Bind)
    end.

%% The relative dir for ssl files.
certs_dir(Type, Name) ->
    iolist_to_binary(filename:join(["listeners", Type, Name])).

convert_certs(ListenerConf) ->
    maps:fold(
        fun(Type, Listeners0, Acc) ->
            Listeners1 =
                maps:fold(
                    fun(Name, Conf0, Acc1) ->
                        Conf1 = convert_certs(Type, Name, Conf0),
                        Acc1#{Name => Conf1}
                    end,
                    #{},
                    Listeners0
                ),
            Acc#{Type => Listeners1}
        end,
        #{},
        ListenerConf
    ).

convert_certs(Type, Name, Conf) ->
    CertsDir = certs_dir(Type, Name),
    case emqx_tls_lib:ensure_ssl_files(CertsDir, get_ssl_options(Conf)) of
        {ok, undefined} ->
            Conf;
        {ok, SSL} ->
            Conf#{<<"ssl_options">> => SSL};
        {error, Reason} ->
            ?SLOG(error, Reason#{msg => "bad_ssl_config", type => Type, name => Name}),
            throw({bad_ssl_config, Reason})
    end.

filter_stacktrace({Reason, _Stacktrace}) -> Reason;
filter_stacktrace(Reason) -> Reason.

%% limiter config should override, not merge
ensure_override_limiter_conf(Conf, #{<<"limiter">> := Limiter}) ->
    Conf#{<<"limiter">> => Limiter};
ensure_override_limiter_conf(Conf, _) ->
    Conf.

get_ssl_options(Conf = #{}) ->
    case maps:find(ssl_options, Conf) of
        {ok, SSL} ->
            SSL;
        error ->
            maps:get(<<"ssl_options">>, Conf, undefined)
    end;
get_ssl_options(_) ->
    undefined.

%% @doc Get QUIC optional settings for low level tunings.
%% @see quicer:quic_settings()
-spec optional_quic_listener_opts(map()) -> proplists:proplist().
optional_quic_listener_opts(Conf) when is_map(Conf) ->
    maps:to_list(
        maps:filter(
            fun(Name, _V) ->
                lists:member(
                    Name,
                    quic_listener_optional_settings()
                )
            end,
            Conf
        )
    ).

-spec quic_listener_optional_settings() -> [atom()].
quic_listener_optional_settings() ->
    [
        max_bytes_per_key,
        %% In conf schema we use handshake_idle_timeout
        handshake_idle_timeout_ms,
        %% In conf schema we use idle_timeout
        idle_timeout_ms,
        %% not use since we are server
        %% tls_client_max_send_buffer,
        tls_server_max_send_buffer,
        stream_recv_window_default,
        stream_recv_buffer_default,
        conn_flow_control_window,
        max_stateless_operations,
        initial_window_packets,
        send_idle_timeout_ms,
        initial_rtt_ms,
        max_ack_delay_ms,
        disconnect_timeout_ms,
        %% In conf schema,  we use keep_alive_interval
        keep_alive_interval_ms,
        %% over written by conn opts
        peer_bidi_stream_count,
        %% over written by conn opts
        peer_unidi_stream_count,
        retry_memory_limit,
        load_balancing_mode,
        max_operations_per_drain,
        send_buffering_enabled,
        pacing_enabled,
        migration_enabled,
        datagram_receive_enabled,
        server_resumption_level,
        minimum_mtu,
        maximum_mtu,
        mtu_discovery_search_complete_timeout_us,
        mtu_discovery_missing_probe_count,
        max_binding_stateless_operations,
        stateless_operation_expiration_ms
    ].

inject_sni_fun(ListenerId, Conf = #{ssl_options := #{ocsp := #{enable_ocsp_stapling := true}}}) ->
    emqx_ocsp_cache:inject_sni_fun(ListenerId, Conf);
inject_sni_fun(_ListenerId, Conf) ->
    Conf.

inject_crl_config(
    Conf = #{ssl_options := #{enable_crl_check := true} = SSLOpts}
) ->
    HTTPTimeout = emqx_config:get([crl_cache, http_timeout], timer:seconds(15)),
    Conf#{
        ssl_options := SSLOpts#{
            %% `crl_check => true' doesn't work
            crl_check => peer,
            crl_cache => {emqx_ssl_crl_cache, {internal, [{http, HTTPTimeout}]}}
        }
    };
inject_crl_config(Conf) ->
    Conf.

maybe_unregister_ocsp_stapling_refresh(
    ssl = Type, Name, #{ssl_options := #{ocsp := #{enable_ocsp_stapling := false}}} = _Conf
) ->
    unregister_ocsp_stapling_refresh(Type, Name),
    ok;
maybe_unregister_ocsp_stapling_refresh(_Type, _Name, _Conf) ->
    ok.

unregister_ocsp_stapling_refresh(Type, Name) ->
    ListenerId = listener_id(Type, Name),
    emqx_ocsp_cache:unregister_listener(ListenerId),
    ok.

default_max_conn() ->
    <<"infinity">>.

ensure_max_conns(<<"infinity">>) -> <<"infinity">>;
ensure_max_conns(MaxConn) when is_binary(MaxConn) -> binary_to_integer(MaxConn);
ensure_max_conns(MaxConn) -> MaxConn.
