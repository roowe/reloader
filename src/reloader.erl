%% @copyright 2007 Mochi Media, Inc.
%% @author Matthew Dempsky <matthew@mochimedia.com>
%%
%% @doc Erlang module for automatically reloading modified modules
%% during development.

-module(reloader).
-author("Matthew Dempsky <matthew@mochimedia.com>").

-include_lib("kernel/include/file.hrl").

-behaviour(gen_server).

-export([start_link/1, start/0]).
-export([stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([all_changed/0]).
-export([is_changed/1]).
-export([reload_modules/1, reload_all_changed/0]).
-export([set_check_time/1]).

-record(state, {
          last, 
          tref,
          check_time
         }).

%% External API

%% @spec start_link() -> ServerRet
%% @doc Start the reloader.
start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [2000], []).

start_link(CheckTime) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [CheckTime], []).

%% @spec stop() -> ok
%% @doc Stop the reloader.
stop() ->
    gen_server:call(?MODULE, stop).

set_check_time(Time) ->
    gen_server:cast(?MODULE, {set_check_time, Time}).

%% @spec init([]) -> {ok, State}
%% @doc gen_server init, opens the server in an initial state.
init([CheckTime]) ->
    TimerRef = erlang:send_after(CheckTime, self(), doit),
    {ok, #state{
            last = stamp(),
            tref = TimerRef,
            check_time = CheckTime
           }}.        

%% @spec handle_call(Args, From, State) -> tuple()
%% @doc gen_server callback.
handle_call(stop, _From, State) ->
    {stop, shutdown, stopped, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badrequest}, State}.

%% @spec handle_cast(Cast, State) -> tuple()
%% @doc gen_server callback.
handle_cast({set_check_time, Time}, State) ->
    {noreply, State#state{
                check_time = Time*1000
               }};
handle_cast(_Req, State) ->    
    {noreply, State}.

%% @spec handle_info(Info, State) -> tuple()
%% @doc gen_server callback.
handle_info(doit, #state{
                     check_time = CheckTime
                    } = State) ->
    TimerRef = erlang:send_after(CheckTime, self(), doit),
    Now = stamp(),
    try
        _ = doit(State#state.last, Now)
    catch
        _:R ->
            error_logger:error_msg(
              "reload failed R:~w Stack:~p~n",[R, erlang:get_stacktrace()])
    end,
    {noreply, State#state{
                last = Now,
                tref = TimerRef
               }};
handle_info(Info, State) ->
    error_logger:warning_msg("unknow info ~p~n", [Info]),
    {noreply, State}.

%% @spec terminate(Reason, State) -> ok
%% @doc gen_server termination callback.
terminate(_Reason, State) ->
    erlang:cancel_timer(State#state.tref),
    %% {ok, cancel} = timer:cancel(State#state.tref),
    ok.

%% @spec code_change(_OldVsn, State, _Extra) -> State
%% @doc gen_server code_change callback (trivial).
code_change(_Vsn, State, _Extra) ->
    {ok, State}.

%% @spec reload_modules([atom()]) -> [{module, atom()} | {error, term()}]
%% @doc code:purge/1 and code:load_file/1 the given list of modules in order,
%%      return the results of code:load_file/1.
reload_modules(Modules) ->
    [begin code:purge(M), code:load_file(M) end || M <- Modules].

%% @spec all_changed() -> [atom()]
%% @doc Return a list of beam modules that have changed.
all_changed() ->
    [M || {M, Fn} <- code:all_loaded(), is_list(Fn), is_changed(M)].

%% @spec is_changed(atom()) -> boolean()
%% @doc true if the loaded module is a beam with a vsn attribute
%%      and does not match the on-disk beam file, returns false otherwise.
is_changed(M) ->
    try
        module_vsn(M:module_info()) =/= module_vsn(code:get_object_code(M))
    catch _:_ ->
            false
    end.

reload_all_changed() ->
    reload_modules(all_changed()).

%% Internal API

module_vsn({M, Beam, _Fn}) ->
    {ok, {M, Vsn}} = beam_lib:version(Beam),
    Vsn;
module_vsn(L) when is_list(L) ->
    {_, Attrs} = lists:keyfind(attributes, 1, L),
    {_, Vsn} = lists:keyfind(vsn, 1, Attrs),
    Vsn.

doit(From, To) ->
    [case file:read_file_info(Filename) of
         {ok, #file_info{mtime = Mtime}} when Mtime >= From, Mtime < To ->
             reload(Module);
         {ok, _} ->
             unmodified;
         {error, enoent} ->
             %% The Erlang compiler deletes existing .beam files if
             %% recompiling fails.  Maybe it's worth spitting out a
             %% warning here, but I'd want to limit it to just once.
             gone;
         {error, Reason} ->
             error_logger:error_msg("Error reading ~s's file info: ~p~n",
                                    [Filename, Reason]),
             error
     end || {Module, Filename} <- code:all_loaded(), is_list(Filename)].

reload(Module) ->
    error_logger:info_msg("Reloading ~p ...", [Module]),
    code:purge(Module),
    case code:load_file(Module) of
        {module, Module} ->
            error_logger:info_msg("reload ~w ok.~n", [Module]),
            reload;
        {error, Reason} ->
            error_logger:error_msg("reload fail: ~p.~n", [Reason]),
            error
    end.


stamp() ->
    erlang:localtime().

