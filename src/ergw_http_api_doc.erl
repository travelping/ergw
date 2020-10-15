-module(ergw_http_api_doc).

-behaviour(trails_handler).

-export([trails/0]).

%%% ==================================================================
%%% Macros: HTTP Response Codes
%%% ==================================================================

-define(HTTP_200_OK, 200).
-define(HTTP_400_BAD_REQUEST, 400).
-define(HTTP_404_NOT_FOUND, 404).

%%% ==================================================================
%%% Trails Callbacks
%%% ==================================================================

trails() ->
    %% Definitions
    DefinitionResponseVersion = <<"response-api-v1-version">>,
    DefinitionResponseStatus = <<"response-api-v1-status">>,
    DefinitionResponseStatusAcceptNew = <<"response-api-v1-status-accept-new">>,
    
    %% Properties
    PropertyResponseVersion = #{
        <<"version">> => #{
            type => <<"string">>,
            description => <<"Returns version of the erGW">>,
            default => <<"2.6.1+build.848.refd028be4">>
        }
    },
    
    PropertyResponseStatus = #{
        <<"acceptNewRequests">> => #{
            type => <<"boolean">>,
            description => <<"Accept New Requests">>,
            default => true
        },
        <<"plmnId">> => #{
            type => <<"object">>,
            properties => #{
                <<"mcc">> => #{
                    type => <<"string">>,
                    default => <<"001">>,
                    description => <<"mcc">>
                },
                <<"mnc">> => #{
                    type => <<"string">>,
                    default => <<"01">>,
                    description => <<"mnc">>
                }
            }
        }
    },
    
    PropertyResponseStatusAcceptNew = #{
        <<"acceptNewRequests">> => #{
            type => <<"boolean">>,
            description => <<"Accept New Requests">>,
            default => true
        }
    },

    %% Definitions and properties
    DefinitionsAndProperties = [
        {DefinitionResponseVersion, PropertyResponseVersion},
        {DefinitionResponseStatus, PropertyResponseStatus},
        {DefinitionResponseStatusAcceptNew, PropertyResponseStatusAcceptNew}
    ],
    
    %% Add definitions
    [cowboy_swagger:add_definition(Def, Prop) || {Def, Prop} <- DefinitionsAndProperties],

    % In path
    InPathStatusAcceptNew = #{
            name => <<"value">>,
            description => <<"true - accept new requests, false - do not accept new requests">>,
            in => <<"path">>,
            required => true,
            type => <<"string">>,
            default => <<"true">>
    },
    
    InPathMetricsRegistry = #{
            name => <<"registry">>,
            description => <<"Registry metrics">>,
            in => <<"path">>,
            type => <<"string">>,
            required => true,
            default => <<"default">>
    },

    % Meta data
    MetadataVersion = #{
        get => #{
            tags => [<<"Version">>],
            summary => <<"Get the erGW version">>,
            description => <<"Returns version of the erGW">>,
            produces => [<<"application/json">>],
            responses => #{
                ?HTTP_200_OK => #{
                    description => <<"OK">>, 
                    schema => cowboy_swagger:schema(DefinitionResponseVersion)
                }
            }
        }
    },
    
    MetadataStatus = #{
        get => #{
            tags => [<<"Status">>],
            summary => <<"Get the status">>,
            description => <<"Returns the current status">>,
            produces => [<<"application/json">>],
            responses => #{
                ?HTTP_200_OK => #{
                    description => <<"OK">>, 
                    schema => cowboy_swagger:schema(DefinitionResponseStatus)
                }
            }
        }
    },

    MetadataStatusAcceptNew = #{
        get => #{
            tags => [<<"Status Accept New">>],
            summary => <<"Get the current 'accept-new' status">>,
            description => <<"Get the current 'accept-new' status">>,
            produces => [<<"application/json">>],
            responses => #{
                ?HTTP_200_OK => #{
                    description => <<"OK">>, 
                    schema => cowboy_swagger:schema(DefinitionResponseStatusAcceptNew)
                }
            }
        }
    },
    
    MetadataStatusAcceptNewPost = #{
        post => #{
            tags => [<<"Status Accept New">>],
            summary => <<"Enables/Disables accepting new requests">>,
            description => <<"Enables/Disables accepting new requests">>,
            produces => [<<"application/json">>],
            parameters => [InPathStatusAcceptNew],
            responses => #{
                ?HTTP_200_OK => #{
                    description => <<"OK">>, 
                    schema => cowboy_swagger:schema(DefinitionResponseStatusAcceptNew)
                },
                ?HTTP_400_BAD_REQUEST => #{
                    description => <<"Bad Request">>
                }
            }
        }
    },

    MetadataMetrics = #{
        get => #{
            tags => [<<"Metrics">>],
            summary => <<"Get the metrics">>,
            description => <<"Returns the metrics">>,
            produces => [<<"text/plain">>],
            responses => #{
                ?HTTP_200_OK => #{
                    description => <<"OK">>
                },
                ?HTTP_404_NOT_FOUND => #{
                    description => <<"Not Found">>
                }
            }
        }
    },

    MetadataMetricsRegistry = #{
        get => #{
            tags => [<<"Metrics">>],
            summary => <<"Get the metrics">>,
            description => <<"Returns the metrics">>,
            produces => [<<"text/plain">>],
            parameters => [InPathMetricsRegistry],
            responses => #{
                ?HTTP_200_OK => #{
                    description => <<"OK">>
                },
                ?HTTP_404_NOT_FOUND => #{
                    description => <<"Not Found">>
                }
            }
        }
    },

    %% Paths
    PathApiVersion = "/api/v1/version",
    PathApiStatus = "/api/v1/status",
    PathApiStatusAcceptNew = "/api/v1/status/accept-new",
    PathApiStatusAcceptNewPost = "/api/v1/status/accept-new/:value",
    PathMetrics = "/metrics",
    PathMetricsRegistry = "/metrics/[:registry]",

    %% Options
    StoreOptions = [
        {PathApiVersion, #{path => PathApiVersion}, MetadataVersion, http_api_handler},
        {PathApiStatus, #{path => PathApiStatus}, MetadataStatus, http_api_handler},
        {PathApiStatusAcceptNew, #{path => PathApiStatusAcceptNew}, MetadataStatusAcceptNew, http_api_handler},
        {PathApiStatusAcceptNewPost, #{path => PathApiStatusAcceptNewPost}, MetadataStatusAcceptNewPost, http_api_handler},
        {PathMetrics, #{path => PathMetrics}, MetadataMetrics, http_api_handler},
        {PathMetricsRegistry, #{path => PathMetricsRegistry}, MetadataMetricsRegistry, http_api_handler}
    ],

    %% Trail all data
    [trails:trail(Path, Module, Options, Metadata) || {Path, Options, Metadata, Module} <- StoreOptions].