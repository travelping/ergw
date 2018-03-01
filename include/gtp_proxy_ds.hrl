% #proxy_info{
%             imsi = <<"222222222222222">>,
%             msisdn = <<"12345678900">>,
%             apn = [<<"apn1">>],
%             ggsns = [
%                 #proxy_info_ggsn{
%                     address = {192, 168, 1, 1}, 
%                     context = <<"Context">>,
%                     dst_apn = [<"example">>, <<"com">>],
%                     restrictions = [{v1,true},
%                                     {v2,false}]
%             }]
%            }. 

-record(proxy_ggsn, {
      node              :: list(),
      address           :: inet:ip_address(),
      context           :: binary(),
      dst_apn           :: [binary()],
      restrictions = [] :: [{'v1', boolean()} |
                            {'v2', boolean()}]
     }).

-record(proxy_info, {
      imsi       :: binary(),
      msisdn     :: binary(),
      src_apn    :: [binary()],
      ggsns = [] :: [#proxy_ggsn{}]
     }).
