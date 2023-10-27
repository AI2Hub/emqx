%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(emqx_audit_api_SUITE).
-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

-define(CONF_DEFAULT, #{
    node =>
        #{
            name => "emqx1@127.0.0.1",
            cookie => "emqxsecretcookie",
            data_dir => "data"
        },
    log => #{
        audit =>
            #{
                enable => true,
                ignore_high_frequency_request => true,
                level => info,
                max_filter_size => 15,
                rotation_count => 2,
                rotation_size => "10MB",
                time_offset => "system"
            }
    }
}).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    _ = application:load(emqx_conf),
    emqx_config:erase_all(),
    emqx_mgmt_api_test_util:init_suite([emqx_ctl, emqx_conf, emqx_audit]),
    ok = emqx_common_test_helpers:load_config(emqx_enterprise_schema, ?CONF_DEFAULT),
    emqx_config:save_schema_mod_and_names(emqx_enterprise_schema),
    application:set_env(emqx, boot_modules, []),
    emqx_conf_cli:load(),
    Config.

end_per_suite(_) ->
    emqx_mgmt_api_test_util:end_suite([emqx_audit, emqx_conf, emqx_ctl]).

t_http_api(_) ->
    process_flag(trap_exit, true),
    AuditPath = emqx_mgmt_api_test_util:api_path(["audit"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    {ok, Zones} = emqx_mgmt_api_configs_SUITE:get_global_zone(),
    NewZones = emqx_utils_maps:deep_put([<<"mqtt">>, <<"max_qos_allowed">>], Zones, 1),
    {ok, #{<<"mqtt">> := Res}} = emqx_mgmt_api_configs_SUITE:update_global_zone(NewZones),
    ?assertMatch(#{<<"max_qos_allowed">> := 1}, Res),
    {ok, Res1} = emqx_mgmt_api_test_util:request_api(get, AuditPath, "limit=1", AuthHeader),
    ?assertMatch(
        #{
            <<"data">> := [
                #{
                    <<"from">> := <<"rest_api">>,
                    <<"operation_id">> := <<"/configs/global_zone">>,
                    <<"source_ip">> := <<"127.0.0.1">>,
                    <<"source">> := _,
                    <<"http_request">> := #{
                        <<"method">> := <<"put">>,
                        <<"body">> := #{<<"mqtt">> := #{<<"max_qos_allowed">> := 1}},
                        <<"bindings">> := _,
                        <<"headers">> := #{<<"authorization">> := <<"******">>}
                    },
                    <<"http_status_code">> := 200,
                    <<"operation_result">> := <<"success">>,
                    <<"operation_type">> := <<"configs">>
                }
            ]
        },
        emqx_utils_json:decode(Res1, [return_maps])
    ),
    ok.

t_cli(_Config) ->
    ok = emqx_ctl:run_command(["conf", "show", "log"]),
    AuditPath = emqx_mgmt_api_test_util:api_path(["audit"]),
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    {ok, Res} = emqx_mgmt_api_test_util:request_api(get, AuditPath, "limit=1", AuthHeader),
    #{<<"data">> := Data} = emqx_utils_json:decode(Res, [return_maps]),
    ?assertMatch(
        [
            #{
                <<"from">> := <<"cli">>,
                <<"operation_id">> := <<"">>,
                <<"source_ip">> := <<"">>,
                <<"operation_type">> := <<"conf">>,
                <<"args">> := [<<"show">>, <<"log">>],
                <<"node">> := _,
                <<"source">> := <<"">>,
                <<"http_request">> := <<"">>
            }
        ],
        Data
    ),

    %% check filter
    {ok, Res1} = emqx_mgmt_api_test_util:request_api(get, AuditPath, "from=cli", AuthHeader),
    #{<<"data">> := Data1} = emqx_utils_json:decode(Res1, [return_maps]),
    ?assertEqual(Data, Data1),
    {ok, Res2} = emqx_mgmt_api_test_util:request_api(
        get, AuditPath, "from=erlang_console", AuthHeader
    ),
    ?assertMatch(#{<<"data">> := []}, emqx_utils_json:decode(Res2, [return_maps])),
    ok.

t_kickout_clients_without_log(_) ->
    process_flag(trap_exit, true),
    AuditPath = emqx_mgmt_api_test_util:api_path(["audit"]),
    {ok, AuditLogs1} = emqx_mgmt_api_test_util:request_api(get, AuditPath),
    kickout_clients(),
    {ok, AuditLogs2} = emqx_mgmt_api_test_util:request_api(get, AuditPath),
    ?assertEqual(AuditLogs1, AuditLogs2),
    ok.

kickout_clients() ->
    ClientId1 = <<"client1">>,
    ClientId2 = <<"client2">>,
    ClientId3 = <<"client3">>,

    {ok, C1} = emqtt:start_link(#{
        clientid => ClientId1,
        proto_ver => v5,
        properties => #{'Session-Expiry-Interval' => 120}
    }),
    {ok, _} = emqtt:connect(C1),
    {ok, C2} = emqtt:start_link(#{clientid => ClientId2}),
    {ok, _} = emqtt:connect(C2),
    {ok, C3} = emqtt:start_link(#{clientid => ClientId3}),
    {ok, _} = emqtt:connect(C3),

    timer:sleep(300),

    %% get /clients
    ClientsPath = emqx_mgmt_api_test_util:api_path(["clients"]),
    {ok, Clients} = emqx_mgmt_api_test_util:request_api(get, ClientsPath),
    ClientsResponse = emqx_utils_json:decode(Clients, [return_maps]),
    ClientsMeta = maps:get(<<"meta">>, ClientsResponse),
    ClientsPage = maps:get(<<"page">>, ClientsMeta),
    ClientsLimit = maps:get(<<"limit">>, ClientsMeta),
    ClientsCount = maps:get(<<"count">>, ClientsMeta),
    ?assertEqual(ClientsPage, 1),
    ?assertEqual(ClientsLimit, emqx_mgmt:default_row_limit()),
    ?assertEqual(ClientsCount, 3),

    %% kickout clients
    KickoutPath = emqx_mgmt_api_test_util:api_path(["clients", "kickout", "bulk"]),
    KickoutBody = [ClientId1, ClientId2, ClientId3],
    {ok, 204, _} = emqx_mgmt_api_test_util:request_api_with_body(post, KickoutPath, KickoutBody),

    {ok, Clients2} = emqx_mgmt_api_test_util:request_api(get, ClientsPath),
    ClientsResponse2 = emqx_utils_json:decode(Clients2, [return_maps]),
    ?assertMatch(#{<<"meta">> := #{<<"count">> := 0}}, ClientsResponse2).