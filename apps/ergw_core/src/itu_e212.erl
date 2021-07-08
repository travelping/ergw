%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(itu_e212).

-export([split_imsi/1]).

-ifdef(TEST).
-export([mcn_size/1]).
-endif.

%%====================================================================
%% API
%%====================================================================

split_imsi(<<MCC:3/bytes, Rest/binary>> = _IMSI) ->
    Size = mcn_size(MCC),
    <<MNC:Size/bytes, MSIN/binary>> = Rest,
    {MCC, MNC, MSIN};
split_imsi(IMSI) ->
    {undefined, undefined, IMSI}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% only list the exceptions
mcn_size(<<"302">>) -> 3;
mcn_size(<<"310">>) -> 3;
mcn_size(<<"311">>) -> 3;
mcn_size(<<"312">>) -> 3;
mcn_size(<<"313">>) -> 3;
mcn_size(<<"316">>) -> 3;
mcn_size(<<"334">>) -> 3;
mcn_size(<<"338">>) -> 3;
mcn_size(<<"342">>) -> 3;
mcn_size(<<"344">>) -> 3;
mcn_size(<<"346">>) -> 3;
mcn_size(<<"348">>) -> 3;
mcn_size(<<"350">>) -> 3;
mcn_size(<<"352">>) -> 3;
mcn_size(<<"354">>) -> 3;
mcn_size(<<"356">>) -> 3;
mcn_size(<<"358">>) -> 3;
mcn_size(<<"360">>) -> 3;
mcn_size(<<"365">>) -> 3;
mcn_size(<<"366">>) -> 3;
mcn_size(<<"374">>) -> 3;
mcn_size(<<"376">>) -> 3;
mcn_size(<<"405">>) -> 3;
mcn_size(<<"708">>) -> 3;
mcn_size(<<"714">>) -> 3;
mcn_size(<<"722">>) -> 3;
mcn_size(<<"732">>) -> 3;
mcn_size(<<"738">>) -> 3;
mcn_size(<<"750">>) -> 3;
mcn_size(_) -> 2.
