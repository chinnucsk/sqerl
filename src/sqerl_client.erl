%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Kevin Smith <kevin@opscode.com>
%% @doc Abstraction around interacting with SQL databases
%% Copyright 2011-2012 Opscode, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(sqerl_client).

-include_lib("sqerl.hrl").

-behaviour(gen_server).

-define(LOG_STATEMENT(Name, Args), case application:get_env(sqerl, log_statements) of
                                       undefined ->
                                           ok;
                                       {ok, false} ->
                                           ok;
                                       {ok, true} ->
                                           error_logger:info_msg("(~p) Executing statement ~p with args ~p~n", [self(), Name, Args])
                                   end).

-define(LOG_RESULT(Result), case application:get_env(sqerl, log_statements) of
                                undefined ->
                                    ok;
                                {ok, false} ->
                                    ok;
                                {ok, true} ->
                                    error_logger:info_msg("(~p) Result: ~p~n", [self(), Result])
                            end).

%% API
-export([start_link/0,
         start_link/1,
         execute/2,
         execute/3,
         close/1,
         prepare/3,
         unprepare/2,
         sql_parameter_style/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {cb_mod,
                cb_state,
                timeout}).

%% behavior callback definitions
-callback init(Config :: [{atom(), term()}]) ->
    term().
-callback execute(StatementOrQuery :: sqerl_query(), Parameters :: [any()], State :: term()) ->
    {sqerl_results(), State :: term()}.
-callback is_connected(State :: term()) ->
    {true, State :: term()} | false.
-callback sql_parameter_style() ->
    atom().
-callback prepare(StatementName :: atom(), SQL :: sqerl_sql(), State :: term()) ->
    {ok, State :: term()}.
-callback unprepare(StatementName :: atom(), _, State :: term()) ->
    {ok, State :: term()}.

%% @doc Prepare a statement
%%
-spec prepare(pid(), atom(), binary()) -> ok | {error, any()}.
prepare(Cn, Name, SQL) when is_pid(Cn), is_atom(Name), is_binary(SQL) ->
    gen_server:call(Cn, {prepare, Name, SQL}, infinity).

%% @doc Unprepare a previously prepared statement
-spec unprepare(pid(), atom()) -> ok | {error, any()}.
unprepare(Cn, Name) when is_pid(Cn), is_atom(Name) ->
    %% downstream code standardizes on {Call, StmtNameOrSQL, Args}
    %% for simplicity so here we just set Args to none
    gen_server:call(Cn, {unprepare, Name, none}, infinity).

%% @doc Execute SQL or prepared statement with no parameters.
%% See execute/3 for return values.
-spec execute(pid(), sqerl_query()) -> sqerl_results().
execute(Cn, QueryOrStatement) ->
    execute(Cn, QueryOrStatement, []).

%% @doc Execute SQL or prepared statement with parameters.
-spec execute(pid(), sqerl_query(), [any()]) -> sqerl_results().
execute(Cn, QueryOrStatement, Parameters) ->
    gen_server:call(Cn, {execute, QueryOrStatement, Parameters}, infinity).

%%% Close a connection
-spec close(pid()) -> ok.
close(Cn) ->
    gen_server:call(Cn, close).


start_link() ->
    gen_server:start_link(?MODULE, [], []).
start_link(DbType) ->
    gen_server:start_link(?MODULE, [DbType], []).

init([]) ->
    init(drivermod());
init(CallbackMod) ->
    IdleCheck = ev(idle_check, 1000),

    Statements = read_statements_from_config(),

    Config = [{host, ev(db_host)},
              {port, ev(db_port)},
              {user, ev(db_user)},
              {pass, ev(db_pass)},
              {db, ev(db_name)},
              {timeout, ev(db_timeout, 5000)},
              {idle_check, IdleCheck},
              {prepared_statements, Statements},
              {column_transforms, ev(column_transforms)}],
    case CallbackMod:init(Config) of
        {ok, CallbackState} ->
            Timeout = IdleCheck,
            {ok, #state{cb_mod=CallbackMod, cb_state=CallbackState,
                        timeout=Timeout}, Timeout};
        Error ->
            {stop, Error}
    end.

handle_call({Call, QueryOrStatementName, Args}, From, State) ->
    exec_driver({Call, QueryOrStatementName, Args}, From, State);
handle_call(close, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, #state{timeout=Timeout}=State) ->
    {reply, ignored, State, Timeout}.

handle_cast(_Msg, #state{timeout=Timeout}=State) ->
    {noreply, State, Timeout}.

handle_info(timeout, #state{cb_mod=CBMod, cb_state=CBState, timeout=Timeout}=State) ->
    case CBMod:is_connected(CBState) of
        {true, CBState1} ->
            {noreply, State#state{cb_state=CBState1}, Timeout};
        false ->
            error_logger:warning_msg("Failed to verify idle connection. Shutting down ~p~n",
                                     [self()]),
            {stop, shutdown, State}
    end;
handle_info(_Info, #state{timeout=Timeout}=State) ->
    {noreply, State, Timeout}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @doc Call DB driver process
exec_driver({Call, QueryOrName, Args}, _From, #state{cb_mod=CBMod, cb_state=CBState, timeout=Timeout}=State) ->
    ?LOG_STATEMENT(QueryOrName, Args),
    {Result, NewCBState} = apply(CBMod, Call, [QueryOrName, Args, CBState]),
    ?LOG_RESULT(Result),
    {reply, Result, State#state{cb_state=NewCBState}, Timeout}.

-spec read_statements([{atom(), term()}]
                      | string()
                      | {atom(), atom(), list()}) -> [{atom(), binary()}].
%% @doc Prepared statements can be provides as a list of `{atom(), binary()}' tuples, as a
%% path to a file that can be consulted for such tuples, or as `{M, F, A}' such that
%% `apply(M, F, A)' returns the statements tuples.
read_statements({Mod, Fun, Args}) ->
    apply(Mod, Fun, Args);
read_statements(L = [{Label, SQL}|_T]) when is_atom(Label) andalso is_binary(SQL) ->
    L;
read_statements(Path) when is_list(Path) ->
    {ok, Statements} = file:consult(Path),
    Statements.


%% @doc Returns SQL parameter style atom, e.g. qmark, dollarn.
%% Note on approach: here we rely on sqerl config in
%% application environment to retrieve db type and from there
%% call the appropriate driver module.
%% It would be better to not be tied to how sqerl is
%% configured and instead retrieve that from state somewhere.
%% However, retrieving that from state implies making a call
%% to a process somewhere which comes with its set of
%% implications, contention being a potential issue.
%%-spec sql_parameter_style() -> atom().
sql_parameter_style() ->
    Mod = drivermod(),
    Mod:sql_parameter_style().

%% @doc Returns DB driver module atom based on application config. First checks the key
%% `db_driver_mod'. If this is undefined, checks for the deprecated `db_type' and
%% translates.
-spec drivermod() -> atom().
drivermod() ->
    case ev(db_driver_mod, undefined) of
        undefined ->
            error_logger:warning_msg("Missing config {sqerl, db_driver_mod}. "
                                     "Falling back to deprecated {sqerl, db_type} value"),
            case ev(db_type, undefined) of
                undefined ->
                    Msg = {missing_application_config, sqerl, db_driver_mod},
                    error_logger:error_report(Msg),
                    error(Msg);
                pgsql ->
                    %% default pgsql driver mod
                    error_logger:warning_report({deprecated_application_config,
                                                 sqerl,
                                                 db_type,
                                                 "use db_driver_mod instead"}),
                    sqerl_pgsql_client;
                BadType ->
                    Msg = {unsupported_db_type, sqerl, BadType},
                    error_logger:error_report(Msg),
                    error(Msg)
            end;
        DriverMod when is_atom(DriverMod) ->
            DriverMod;
        Error ->
            Msg = {invalid_application_config, sqerl, db_driver_mod, Error},
            error_logger:error_report(Msg),
            error(Msg)
    end.

%% Short for "environment value", just provides some sugar for grabbing config values
ev(Key) ->
    case application:get_env(sqerl, Key) of
        {ok, V} -> V;
        undefined ->
            Msg = {missing_application_config, sqerl, Key},
            error_logger:error_report(Msg),
            error(Msg)
    end.
ev(Key, Default) ->
    case application:get_env(sqerl, Key) of
        undefined -> Default;
        {ok, V} -> V
    end.

read_statements_from_config() ->
    StatementSource = ev(prepared_statements),
    try
        read_statements(StatementSource)
    catch
        error:Reason ->
            Msg = {incorrect_application_config, sqerl, {prepared_statements, Reason, erlang:get_stacktrace()}},
            error_logger:error_report(Msg),
            error(Msg)
    end.
