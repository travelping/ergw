% #proxy_info{
%             imsi = <<"222222222222222">>,
%             msisdn = <<"12345678900">>,
%             ggsns = [
%                 #proxy_info_ggsn{
%                     address = {192, 168, 1, 1}, 
%                     context = <<"Context">>,
%                     apn = [<"example">>, <<"com">>],
%                     restrictions = [{v1,true},
%                                     {v2,false}]
%             }]
%            }. 

-record(proxy_ggsn, {
      address           :: inet:ip_address(),
      context           :: binary(),
      apn               :: [binary()],
      restrictions = [] :: [{'v1', boolean()} |
                            {'v2', boolean()}]
     }).

-record(proxy_info, {
      imsi       :: binary(),
      msisdn     :: binary(),
      ggsns = [] :: [#proxy_ggsn{}]
     }).
