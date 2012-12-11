%% ssync: Rebarized Erlang code always compiled
%%
%% Copyright (c) 2012 Milan Svoboda (milan.svoboda@centrum.cz)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------

-module(ssync).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-define(log(T),
        error_logger:info_report(
          [process_info(self(),current_function),{line,?LINE},T])).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, rebar/1, reload/1]).

-export([start/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start() ->
    application:start(ets_manager),
    application:start(erlinotify),
    application:start(ssync),
    rebar('get-deps'),
    rebar(compile).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

rebar(compile) ->
    gen_server:cast(?MODULE, {compile});

rebar('get-deps') ->
    gen_server:cast(?MODULE, {'get-deps'}).

reload(ModuleName) ->
    gen_server:cast(?MODULE, {reload, ModuleName}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State} |
%%          {ok, State, Timeout} |
%%          ignore |
%%          {stop, Reason}
%%----------------------------------------------------------------------

init(_Args) ->
    watch(ssync_rebar_config:get_all_dirs(".")),
    {ok, []}.

%%----------------------------------------------------------------------
%% Func: handle_call/3
%% Returns: {reply, Reply, State} |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State} |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, Reply, State} | (terminate/2 is called)
%%          {stop, Reason, State} (terminate/2 is called)
%%----------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%----------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State} |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State} (terminate/2 is called)
%%----------------------------------------------------------------------
handle_cast(stop, State) ->
  {stop, normal, State};

handle_cast({compile}, State) ->
    ssync_notify:notify("ssync: build started", []),
    ssync_cmd:cmd("rebar", ["compile"], fun parse_output/2),
    ssync_notify:notify("ssync: build finished", []),
    {noreply, State};

handle_cast({'get-deps'}, State) ->
    ssync_notify:notify("ssync: get-deps started", []),
    ssync_cmd:cmd("rebar", ["get-deps"], fun parse_output/2),
    ssync_notify:notify("ssync: get-deps finished", []),
    watch(ssync_rebar_config:get_all_dirs(".")),
    {noreply, State};

handle_cast({reload, ModuleName}, State) ->
    Ext = string:to_lower(filename:extension(ModuleName)),
    case Ext of
        ".beam" ->
            Module = list_to_atom(filename:rootname(ModuleName)),
            code:purge(Module),
            {module, Module} = code:load_file(Module),
            Summary = io_lib:format("ssync: reloaded (~s)", [Module]),
            ssync_notify:notify(Summary, []);
        _ -> ok
    end,
    {noreply, State};

handle_cast(Msg, State) ->
  ?log({unknown_message, Msg}),
  {noreply, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State} |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State} (terminate/2 is called)
%%----------------------------------------------------------------------
handle_info(Info, State) ->
  ?log({unknown_message, Info}),
  {noreply, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any (ignored by gen_server)
%%----------------------------------------------------------------------
terminate(_Reason, State) ->
    {close, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

watch({Path, reload = CallbackName}) ->
    code:add_path(Path),
    watch_recursive(Path, CallbackName);

watch({Path, watch_rebar_config = CallbackName}) ->
    erlinotify:watch(Path, get_callback(CallbackName));

watch({Path, CallbackName}) ->
    watch_recursive(Path, CallbackName);

watch([]) ->
    ok;

watch([F|R]) ->
    watch(F),
    watch(R).

watch_recursive(Path, CallbackName) ->
    Callback = get_callback(CallbackName),
    Dirs = subdirs(Path) ++ [{dir, Path}],

    [erlinotify:watch(X, Callback) ||
        {dir, X} <- lists:flatten(Dirs) ], ok.

get_callback(reload) ->
    fun do_reload/1;
get_callback(compile) ->
    fun do_compile/1;
get_callback(watch_rebar_config) ->
    fun do_watch_rebar_config/1.

subdirs(Path) ->
    [[{dir, Y} | subdirs(Y)] ||
            Y <- filelib:wildcard(filename:join([Path, "*"])),
            filelib:is_dir(Y) ].

print_project(_, []) ->
    ok;

print_project(Project, Msgs) ->
    ssync_notify:notify(io_lib:format("ssync: build (~s)", [Project]), Msgs).

parse_output(eof, {Project, Msgs} = _Acc) ->
    print_project(Project, lists:reverse(Msgs));

parse_output({eol, BinMsg}, Acc) ->
    case re:run(BinMsg, "==> (\\S+)", [{capture, [1], list}]) of
        {match, [Project]} ->
            case Acc of
                {Project, _} ->
                    Acc;
                {PrevProject, PrevMsgs} ->
                    print_project(PrevProject, lists:reverse(PrevMsgs)),
                    {Project, []};
                _ ->
                    {Project, []}
            end;
        nomatch ->
            {Project, Msgs} = Acc,
            {Project, [BinMsg | Msgs]}
    end;

parse_output({noeol, BinMsg}, {Project, Acc}) ->
	StartLine = hd(Acc),
	{Project, [<<StartLine/binary, BinMsg/binary>> | tl(Acc)]}.

do_compile({File, dir, create, _Cookie, Name} = _Info) ->
    FN = filename:join(File, Name),
    erlinotify:watch(FN, fun do_compile/1);

do_compile({File, dir, delete, _Cookie, Name} = _Info) ->
    FN = filename:join(File, Name),
    erlinotify:unwatch(FN);

do_compile({_File, file, close_write, _Cookie, Name} = _Info) ->
    Ext = string:to_lower(filename:extension(Name)),
    {ok, Exts} = application:get_env(ssync, extension),
    case lists:any(fun(X) -> X == Ext end, Exts) of
        true ->
            rebar(compile);
        false ->
            ok
    end;

do_compile({_File, _Type, _Event, _Cookie, _Name} = _Info) ->
    ok.

do_reload({File, dir, create, _Cookie, Name} = _Info) ->
    FN = filename:join(File, Name),
    erlinotify:watch(FN, fun do_reload/1);

do_reload({File, dir, delete, _Cookie, Name} = _Info) ->
    FN = filename:join(File, Name),
    erlinotify:unwatch(FN);

do_reload({_File, file, move_to, _Cookie, Name} = _Info) ->
    reload(Name);

do_reload({_File, file, close_write, _Cookie, Name} = _Info) ->
    reload(Name);

do_reload({_File, _Type, _Event, _Cookie, _Name} = _Info) ->
    ok.

do_watch_rebar_config({_File, file, move_to, _Cookie, "rebar.config"} = _Info) ->
    rebar('get-deps');

do_watch_rebar_config({_File, file, close_write, _Cookie, "rebar.config"} = _Info) ->
    rebar('get-deps');

do_watch_rebar_config({_File, _Type, _Event, _Cookie, _Name} = _Info) ->
    ok.
