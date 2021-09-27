[
    {ergw, [
        {'$setup_vars', [{"ORIGIN", {value, "epc.mncxxx.mccxxx.3gppnetwork.org"}}]},
        {plmn_id, {<<"xxx">>, <<"xxx">>}},
        {node_id, <<"ergw_node.$ORIGIN">>},
        {sockets, [
            {cp, [
                {type, 'gtp-u'},
                {vrf, cp},
                {ip, {192, 168, 1, 1}},
                freebind,
                {reuseaddr, true},
                {rcvbuf, 4194304}
            ]},
            {access, [
                {type, 'gtp-c'},
                {ip, {192, 168, 3, 1}},
                freebind,
                {rcvbuf, 4194304}
            ]},
            {core, [
                {type, 'gtp-c'},
                {ip, {192, 168, 4, 1}},
                freebind,
                {rcvbuf, 4194304}
            ]},
            {sx, [
                {type, 'pfcp'},
                {node, 'ergw'},
                {name, 'ergw'},
                {socket, cp},
                {ip, {192, 168, 2, 1}},
                {rcvbuf, 4194304}
            ]}
        ]},

        {proxy_ds_uri, <<"http://192.168.0.1:1700/v1/ergwInfo">>},
        {proxy_ds_timeout, 5000},

        {http_api, [{port, 8000}, {ip, {127, 0, 0, 1}}]},

        {handlers, [
            {h1, [
                {handler, pgw_s5s8_proxy},
                {protocol, gn},
                {sockets, [access]},
                {proxy_sockets, [core]},
                {proxy_data_source, ergw_proxy_ds_json_v2},
                {contexts, [{<<"default">>, [{proxy_sockets, [core]}]}]},
                {node_selection, ['SBGDNS']}
            ]},
            {h2, [
                {handler, pgw_s5s8_proxy},
                {protocol, s5s8},
                {sockets, [access]},
                {proxy_sockets, [core]},
                {proxy_data_source, ergw_proxy_ds_json_v2},
                {contexts, [{<<"default">>, [{proxy_sockets, [core]}]}]},
                {node_selection, ['SBGDNS']}
            ]}
        ]},

        {node_selection, [
            { 'dns1',
                { dns, {{192,168,1,53}, 53} }
            },
            {default,
                {static, [
                    {"_default.apn.$ORIGIN", {300, 64536}, [{"x-3gpp-upf", "x-sxa"}], "topon.sx.prox01.$ORIGIN"},
                    {"_default.apn.$ORIGIN", {300, 64536},
                        [
                            {"x-3gpp-pgw", "x-s5-gtp"},
                            {"x-3gpp-pgw", "x-s8-gtp"},
                            {"x-3gpp-pgw", "x-gn"},
                            {"x-3gpp-pgw", "x-gp"}
                        ],
                        "topon.s5s8.pgw0.$ORIGIN"},
                    {"topon.sx.prox01.$ORIGIN", [{192, 168, 2, 1}], []},
                    {"topon.s5s8.pgw0.$ORIGIN", [{192, 168, 3, 1}], []}
                ]}}
        ]},

        {nodes, [
            {default, [
                {vrfs, [
                    {cp, [{features, ['CP-Function']}]},
                    {access, [{features, ['Access']}]},
                    {core, [{features, ['Core']}]},
                    {heartbeat, [
                        {interval, 5000},
                        {timeout, 500},
                        {retry, 5}
                    ]},
                    {request, [
                        {timeout, 30000},
                        {retry, 5}
                    ]}
                ]}
            ]}
        ]},

        {teid, {1,1}},

        {path_management, [
                {t3, 10000},
                {n3, 5},
                {echo, 60000},
                {idle_timeout, 1800000},
                {idle_echo,     600000},
                {down_timeout, 3600000},
                {down_echo,     600000},
                {icmp_error_handling, immediate}]
        }
    ]},

    {ergw_aaa, [
        {ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}
    ]},

    {jobs, [
        {queues, [
            {path_restart, [{standard_counter, 1200}]},
            {create, [{standard_rate, 5000}, {max_size, 100}]},
            {delete, [{standard_counter, 5000}]},
            {other, [{standard_rate, 5000}, {max_size, 500}]}
        ]}
    ]},

    {setup, [{data_dir, "/opt/ergw"}, {log_dir, "/var/log/ergw"}]},

    {hackney, [
        {max_connections, 500}
    ]},

    {kernel, [
        {logger_level, debug},
        {logger, [
            {handler, default, logger_std_h, #{
                level => debug,
                formatter =>
                    {logger_formatter, #{
                        single_line => true,
                        legacy_header => false,
                        template => [time, " ", level, " ", pid, " ", mfa, " : ", msg, "\n"]
                    }},
                config =>
                    #{sync_mode_qlen => 10000, drop_mode_qlen => 10000, flush_qlen => 10000}
            }}
        ]}
    ]}
].
