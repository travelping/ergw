# Tracing

ergw supports OpenTelemetry based tracing.

At the moment this needs to be configured through the opentelemetry app in sys.config

A basic sample config to export to a otel collector:

    {opentelemetry,
     [{resource, [{<<"service.name">>, <<"ergw">>}]},
      {processors,
       [{otel_batch_processor,
         #{exporter =>
               {opentelemetry_exporter,
                #{endpoints => [{http, "localhost", 55681, []}]}
               }
          }
        }
       ]}
     ]}

Sampling can be controlled through the `sampler` key:

    {opentelemetry,
     [{resource, [{<<"service.name">>, <<"ergw">>}]},
      {sampler, {parent_based, #{root => always_on}}}, % default sampler
      {processors,
       [{otel_batch_processor,
         #{exporter =>
               {opentelemetry_exporter,
                #{endpoints => [{http, "localhost", 55681, []}]}
               }
          }
        }
       ]}
     ]}

Check https://github.com/open-telemetry/opentelemetry-erlang/blob/main/apps/opentelemetry/src/otel_sampler.erl#L52
for supported settings.

## Per IMSI Tracing POC

The current branch contains experimental support for tracing GTPv2 Create Session Requests for
a single IMSI.

To use that insert the IMSI into the `ergw_otel_gtp_sampler` trace table:

```
ergw_otel_gtp_sampler:trace('gtp.imsi', <<"111111111111111">>).
```
