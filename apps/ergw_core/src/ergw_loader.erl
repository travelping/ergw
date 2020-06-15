%% Copyright 2017-2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_loader).

-export([load/3]).

-include_lib("kernel/include/logger.hrl").

load(API, Module, Handler) ->
    Callbacks = API:behaviour_info(callbacks),
    case (lists:subtract(Callbacks, Handler:module_info(exports))) of
	[] ->
	    ok;
	Missing ->
	    error(missing_exports, [Missing])
    end,

    {Body, _} = lists:mapfoldl(fun({FunName, Arity}, Line) ->
				       handler_fun(Handler, Line, FunName, Arity)
			       end, 3, Callbacks),
    Abstract = [{attribute, 1, module, Module},
		{attribute, 2, export, Callbacks} | Body],

    Opts0 = [debug_info, warnings_as_errors, binary],
    Opts = case Handler:module_info(native) of
	       true -> [native | Opts0];
	       _    -> Opts0
	   end,
    {ok, Module, HandlerModBin} = compile:forms(Abstract, Opts),
    {module, Module} = code:load_binary(Module, [], HandlerModBin),

    ?LOG(info, "Handler ~s for ~s successfully installed.", [Handler, Module]),
    ok.

handler_fun(Handler, Line, FunName, Arity) ->
    ArgList = gen_arglist(Line, Arity),
    Abstract = {
      function, Line, FunName, Arity,
      [{clause, Line, ArgList, [],
	[{call, Line + 1,
	  {remote, Line + 1, {atom, Line + 1, Handler}, {atom, Line + 1, FunName}},
	  ArgList
	 }]
       }]
     },
    {Abstract, Line + 2}.

gen_arglist(Line, Arity) ->
    [ {var, Line, list_to_atom("Arg" ++ integer_to_list(N))} || N <- lists:seq(1, Arity)].
