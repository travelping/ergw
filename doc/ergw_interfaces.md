## Interfaces

The SAE-GW, PGW and GGSN interfaces supports DIAMETER and RADIUS over the Gi/SGi interface
as specified by 3GPP TS 29.061 Section 16.
This support is experimental in this version and not all aspects are functional. For RADIUS
only the Authentication and Authorization is full working, Accounting is experimental and
not fully supported. For DIAMETER NASREQ only the Accounting is working.

See [RADIUS.md](RADIUS.md) for a list of supported Attributes.

Many thanks to [On Waves](https://www.on-waves.com/) for sponsoring the RADIUS Authentication implementation.

Example of configuration **RADIUS**:
```erlang
%% ...
{ergw_aaa, [
    {handlers, [
        {ergw_aaa_static, [
            {'Node-Id',        <<"CHANGE-ME">>},            %% <- CHANGE
            {'NAS-Identifier', <<"CHANGE-ME">>},            %% <- CHANGE
            {'NAS-IP-Address', {127,0,0,3}},                %% <- CHANGE
            {'Acct-Interim-Interval',   1800},              %% <- CHANGE
            {'Framed-Protocol',         'PPP'},
            {'Service-Type',            'Framed-User'}
        ]},
        {ergw_aaa_radius, [
            {server,
                {{127,0,0,4}, 1813, <<"CHANGE-ME-SECRET">>} %% <- CHANGE IP and SECRET
            },
            {termination_cause_mapping, [
                {normal, 1},
                {administrative, 6},
                {link_broken, 2},
                {upf_failure, 9},
                {remote_failure, 9},
                {cp_inactivity_timeout, 4},
                {up_inactivity_timeout, 4},
                {'ASR', 6},
                {error, 9},
                {peer_restart, 7}
            ]}
        ]}
    ]},
    {services, [
        {'Default', [
            {handler, 'ergw_aaa_static'}
        ]},
        {'RADIUS-Acct', [
            {handler, 'ergw_aaa_radius'}
        ]}
    ]},
    {apps, [
        {default, [
            {session, ['Default']},
            {procedures, [
                {authenticate, []},
                {authorize, []},
                {start, ['RADIUS-Acct']},
                {interim, ['RADIUS-Acct']},
                {stop, ['RADIUS-Acct']}
            ]}
        ]}
    ]}
]},
%% ...
```
Example of configuration **epc-ocs** `function` of **DIAMETER**:
```erlang
%% ...
{ergw_aaa, [
%% ...
    {functions, [
        {'epc-ocs', [
            {handler, ergw_aaa_diameter},
            {'Origin-Host', <<"CHANGE-ME">>},                           %% <- CHANGE: Origin-Host needs to be resolvable 
                                                                        %% to local IP (either through /etc/hosts or DNS)
            {'Origin-Realm', <<"CHANGE-ME">>},                          %% <- CHANGE
            {transports, [
                [
                    {connect_to, <<"aaa://CHANGE-ME;transport=tcp">>},  %% <- CHANGE
                    {recbuf,131072},                                    %% <- CHANGE
                    {sndbuf,131072}                                     %% <- CHANGE
                ]
            ]}
        ]}
    ]},
%% ...
]},
%% ...
```
Example of configuration **ergw-pgw-epc-rf** `function` of **DIAMETER**:
```erlang
%% ...
{ergw_aaa, [
    %% ...
    {functions, [
        {'ergw-pgw-epc-rf', [
            {handler, ergw_aaa_diameter},
            {'Origin-Host', <<"CHANGE-ME">>},                           %% <- CHANGE
            {'Origin-Realm', <<"CHANGE-ME">>},                          %% <- CHANGE
            {transports, [
                [
                    {connect_to, <<"aaa://CHANGE-ME;transport=tcp">>},  %% <- CHANGE
                    {recbuf,131072},                                    %% <- CHANGE
                    {reuseaddr,false},                                  %% <- CHANGE
                    {sndbuf,131072}                                     %% <- CHANGE
                ]
            ]}
        ]},
    ]},
    {handlers, [
        %% ...
        {ergw_aaa_rf, [
            {function, 'ergw-pgw-epc-rf'},
            {'Destination-Realm', <<"CHANGE-ME">>}                      %% <- CHANGE
        ]},
        {termination_cause_mapping, [
            {normal, 1},           
            {administrative, 4}, 
            {link_broken, 5},      
            {upf_failure, 5},      
            {remote_failure, 1},   
            {cp_inactivity_timeout, 4},
            {up_inactivity_timeout, 4},
            {'ASR', 6},
            {error, 9},
            {peer_restart, 1} 
        ]}
        %% ...
    ]},
    {services, [
        %% ...
        {'Rf', [{handler, 'ergw_aaa_rf'}]},
        %% ...
    ]},
    {apps, [
        {default, [
            %% ...
            {procedures, [
                %% ...
                { {rf, 'Initial'}, ['Rf']},
                { {rf, 'Update'}, ['Rf']},
                { {rf, 'Terminate'}, ['Rf']},
                %% ...
            ]}
        ]}
        %% ...
    ]}
]},
%% ...
```
