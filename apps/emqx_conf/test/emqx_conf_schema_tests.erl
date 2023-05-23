%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_conf_schema_tests).

-include_lib("eunit/include/eunit.hrl").

%% erlfmt-ignore
-define(BASE_CONF,
    """
             node {
                name = \"emqx1@127.0.0.1\"
                cookie = \"emqxsecretcookie\"
                data_dir = \"data\"
             }
             cluster {
                name = emqxcl
                discovery_strategy = static
                static.seeds = ~p
                core_nodes = ~p
             }
    """).

array_nodes_test() ->
    ensure_acl_conf(),
    ExpectNodes = ['emqx1@127.0.0.1', 'emqx2@127.0.0.1'],
    lists:foreach(
        fun(Nodes) ->
            ConfFile = to_bin(?BASE_CONF, [Nodes, Nodes]),
            {ok, Conf} = hocon:binary(ConfFile, #{format => richmap}),
            ConfList = hocon_tconf:generate(emqx_conf_schema, Conf),
            ClusterDiscovery = proplists:get_value(
                cluster_discovery, proplists:get_value(ekka, ConfList)
            ),
            ?assertEqual(
                {static, [{seeds, ExpectNodes}]},
                ClusterDiscovery,
                Nodes
            ),
            ?assertEqual(
                ExpectNodes,
                proplists:get_value(core_nodes, proplists:get_value(mria, ConfList)),
                Nodes
            )
        end,
        [["emqx1@127.0.0.1", "emqx2@127.0.0.1"], "emqx1@127.0.0.1, emqx2@127.0.0.1"]
    ),
    ok.

%% erlfmt-ignore
-define(BASE_AUTHN_ARRAY,
    """
        authentication = [
          {backend = \"http\"
          body {password = \"${password}\", username = \"${username}\"}
          connect_timeout = \"15s\"
          enable_pipelining = 100
          headers {\"content-type\" = \"application/json\"}
          mechanism = \"password_based\"
          method = \"~p\"
          pool_size = 8
          request_timeout = \"5s\"
          ssl {enable = ~p, verify = \"verify_peer\"}
          url = \"~ts\"
        }
        ]
    """
).

-define(ERROR(Reason),
    {emqx_conf_schema, [
        #{
            kind := validation_error,
            reason := integrity_validation_failure,
            result := _,
            validation_name := Reason
        }
    ]}
).

authn_validations_test() ->
    ensure_acl_conf(),
    BaseConf = to_bin(?BASE_CONF, ["emqx1@127.0.0.1", "emqx1@127.0.0.1"]),

    OKHttps = to_bin(?BASE_AUTHN_ARRAY, [post, true, <<"https://127.0.0.1:8080">>]),
    Conf0 = <<BaseConf/binary, OKHttps/binary>>,
    {ok, ConfMap0} = hocon:binary(Conf0, #{format => richmap}),
    ?assert(is_list(hocon_tconf:generate(emqx_conf_schema, ConfMap0))),

    OKHttp = to_bin(?BASE_AUTHN_ARRAY, [post, false, <<"http://127.0.0.1:8080">>]),
    Conf1 = <<BaseConf/binary, OKHttp/binary>>,
    {ok, ConfMap1} = hocon:binary(Conf1, #{format => richmap}),
    ?assert(is_list(hocon_tconf:generate(emqx_conf_schema, ConfMap1))),

    DisableSSLWithHttps = to_bin(?BASE_AUTHN_ARRAY, [post, false, <<"https://127.0.0.1:8080">>]),
    Conf2 = <<BaseConf/binary, DisableSSLWithHttps/binary>>,
    {ok, ConfMap2} = hocon:binary(Conf2, #{format => richmap}),
    ?assertThrow(
        ?ERROR(check_http_ssl_opts),
        hocon_tconf:generate(emqx_conf_schema, ConfMap2)
    ),

    BadHeader = to_bin(?BASE_AUTHN_ARRAY, [get, true, <<"https://127.0.0.1:8080">>]),
    Conf3 = <<BaseConf/binary, BadHeader/binary>>,
    {ok, ConfMap3} = hocon:binary(Conf3, #{format => richmap}),
    ?assertThrow(
        ?ERROR(check_http_headers),
        hocon_tconf:generate(emqx_conf_schema, ConfMap3)
    ),

    BadHeaderWithTuple = binary:replace(BadHeader, [<<"[">>, <<"]">>], <<"">>, [global]),
    Conf4 = <<BaseConf/binary, BadHeaderWithTuple/binary>>,
    {ok, ConfMap4} = hocon:binary(Conf4, #{format => richmap}),
    ?assertThrow(
        ?ERROR(check_http_headers),
        hocon_tconf:generate(emqx_conf_schema, ConfMap4)
    ),
    ok.

%% erlfmt-ignore
-define(LISTENERS,
    """
        listeners.ssl.default.bind = 9999
        listeners.wss.default.bind = 9998
        listeners.wss.default.ssl_options.cacertfile = \"mytest/certs/cacert.pem\"
        listeners.wss.new.bind = 9997
        listeners.wss.new.websocket.mqtt_path = \"/my-mqtt\"
    """
).

listeners_test() ->
    ensure_acl_conf(),
    BaseConf = to_bin(?BASE_CONF, ["emqx1@127.0.0.1", "emqx1@127.0.0.1"]),

    Conf = <<BaseConf/binary, ?LISTENERS>>,
    {ok, ConfMap0} = hocon:binary(Conf, #{format => richmap}),
    {_, ConfMap} = hocon_tconf:map_translate(emqx_conf_schema, ConfMap0, #{format => richmap}),
    #{<<"listeners">> := Listeners} = hocon_util:richmap_to_map(ConfMap),
    #{
        <<"tcp">> := #{<<"default">> := Tcp},
        <<"ws">> := #{<<"default">> := Ws},
        <<"wss">> := #{<<"default">> := DefaultWss, <<"new">> := NewWss},
        <<"ssl">> := #{<<"default">> := Ssl}
    } = Listeners,
    DefaultCacertFile = <<"${EMQX_ETC_DIR}/certs/cacert.pem">>,
    DefaultCertFile = <<"${EMQX_ETC_DIR}/certs/cert.pem">>,
    DefaultKeyFile = <<"${EMQX_ETC_DIR}/certs/key.pem">>,
    ?assertMatch(
        #{
            <<"bind">> := {{0, 0, 0, 0}, 1883},
            <<"enabled">> := true
        },
        Tcp
    ),
    ?assertMatch(
        #{
            <<"bind">> := {{0, 0, 0, 0}, 8083},
            <<"enabled">> := true,
            <<"websocket">> := #{<<"mqtt_path">> := "/mqtt"}
        },
        Ws
    ),
    ?assertMatch(
        #{
            <<"bind">> := 9999,
            <<"ssl_options">> := #{
                <<"cacertfile">> := DefaultCacertFile,
                <<"certfile">> := DefaultCertFile,
                <<"keyfile">> := DefaultKeyFile
            }
        },
        Ssl
    ),
    ?assertMatch(
        #{
            <<"bind">> := 9998,
            <<"websocket">> := #{<<"mqtt_path">> := "/mqtt"},
            <<"ssl_options">> :=
                #{
                    <<"cacertfile">> := <<"mytest/certs/cacert.pem">>,
                    <<"certfile">> := DefaultCertFile,
                    <<"keyfile">> := DefaultKeyFile
                }
        },
        DefaultWss
    ),
    ?assertMatch(
        #{
            <<"bind">> := 9997,
            <<"websocket">> := #{<<"mqtt_path">> := "/my-mqtt"},
            <<"ssl_options">> :=
                #{
                    <<"cacertfile">> := DefaultCacertFile,
                    <<"certfile">> := DefaultCertFile,
                    <<"keyfile">> := DefaultKeyFile
                }
        },
        NewWss
    ),
    ok.

doc_gen_test() ->
    ensure_acl_conf(),
    %% the json file too large to encode.
    {
        timeout,
        60,
        fun() ->
            Dir = "tmp",
            ok = filelib:ensure_dir(filename:join("tmp", foo)),
            I18nFile = filename:join([
                "_build",
                "test",
                "lib",
                "emqx_dashboard",
                "priv",
                "i18n.conf"
            ]),
            _ = emqx_conf:dump_schema(Dir, emqx_conf_schema, I18nFile),
            ok
        end
    }.

to_bin(Format, Args) ->
    iolist_to_binary(io_lib:format(Format, Args)).

ensure_acl_conf() ->
    File = emqx_schema:naive_env_interpolation(<<"${EMQX_ETC_DIR}/acl.conf">>),
    ok = filelib:ensure_dir(filename:dirname(File)),
    case filelib:is_regular(File) of
        true -> ok;
        false -> file:write_file(File, <<"">>)
    end.

log_path_test_() ->
    Fh = fun(Path) ->
        #{<<"log">> => #{<<"file_handlers">> => #{<<"name1">> => #{<<"file">> => Path}}}}
    end,
    Assert = fun(Name, Path, Conf) ->
        ?assertMatch(#{log := #{file_handlers := #{Name := #{file := Path}}}}, Conf)
    end,

    [
        {"default-values", fun() -> Assert(default, "log/emqx.log", check(#{})) end},
        {"file path with space", fun() -> Assert(name1, "a /b", check(Fh(<<"a /b">>))) end},
        {"windows", fun() -> Assert(name1, "c:\\a\\ b\\", check(Fh(<<"c:\\a\\ b\\">>))) end},
        {"unicoded", fun() -> Assert(name1, "路 径", check(Fh(<<"路 径"/utf8>>))) end},
        {"bad utf8", fun() ->
            ?assertThrow(
                {emqx_conf_schema, [
                    #{
                        kind := validation_error,
                        reason := {"bad_file_path_string", _}
                    }
                ]},
                check(Fh(<<239, 32, 132, 47, 117, 116, 102, 56>>))
            )
        end},
        {"not string", fun() ->
            ?assertThrow(
                {emqx_conf_schema, [
                    #{
                        kind := validation_error,
                        reason := {"not_string", _}
                    }
                ]},
                check(Fh(#{<<"foo">> => <<"bar">>}))
            )
        end}
    ].

check(Config) ->
    Schema = emqx_conf_schema,
    {_, Conf} = hocon_tconf:map(Schema, Config, [log], #{
        atom_key => false, required => false, format => map
    }),
    emqx_utils_maps:unsafe_atom_key_map(Conf).
