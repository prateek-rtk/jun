-module(jun_worker).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(JUN_PANDAS, jun_pandas).
-define(JUN_DATAFRAME, jun_dataframe).
-define(JUN_CORE, jun_core).

% the values can be override during initialization
-record(state, {py_pid = undefined :: pid(),
    mon_ref = undefined :: reference()}).

start_link() ->
    % get priv path
    Path = code:priv_dir(jun),
    gen_server:start_link(?MODULE, [Path], []).

init([Path]) ->
    process_flag(trap_exit, true),
    % start the py process and initializes its importing modules
    case python:start([{python_path, Path}]) of
        {ok, PyPid} ->
            MonRef = erlang:monitor(process, PyPid),
            lager:info("initialized default modules for py pid ~p", [PyPid]),
            % load custom encoder & decoder for data frame
            ok = python:call(PyPid, jun_dataframe, setup_dtype, []),
            {ok, #state{py_pid = PyPid, mon_ref = MonRef}};
        Error      ->
            lager:error("cannot initializes py due to ~p", [Error]),
            {stop, Error}
    end.

handle_call({'core.jun', Fn, Args}, _From, State) ->
    PyPid = State#state.py_pid,
    case catch python:call(PyPid, ?JUN_PANDAS, Fn, Args) of
        {'EXIT', {{python, Class, Argument, _Stack}, _}} ->
            {reply, {error, {Class, Argument}}, State};
        Return                                           ->
            {reply, {ok, Return}, State}
    end;

handle_call({'core.jun.dataframe', Args}, _From, State) ->
    PyPid = State#state.py_pid,
    case catch python:call(PyPid, ?JUN_PANDAS, ?JUN_DATAFRAME, Args) of
        {'EXIT', {{python, Class, Argument, _Stack}, _}} ->
            {reply, {error, {Class, Argument}}, State};
        Return                                           ->
            {reply, {ok, Return}, State}
    end;

handle_call({'pandas', Fn, Args}, _From, State) ->
    PyPid = State#state.py_pid,
    case catch python:call(PyPid, pandas, Fn, Args) of
        {'EXIT', {{python, Class, Argument, _Stack}, _}} ->
            {reply, {error, {Class, Argument}}, State};
        Return                                           ->
            {reply, {ok, Return}, State}
    end;

handle_call(_Request, _From, State) ->    
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, _Type, _Object, _Info}, State=#state{mon_ref = MonRef}) ->
    % process py pid is down, which one is the process to restart?
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    % when finish process just stop py_pid
    ok = python:stop(State#state.py_pid),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================
%% Internal Funcionts
%% ===================================