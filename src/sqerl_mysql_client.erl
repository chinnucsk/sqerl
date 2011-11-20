%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Kevin Smith <kevin@opscode.com>
%% @copyright Copyright 2011 Opscode, Inc.
%% @end
%% @doc Abstraction around interacting with mysql databases
-module(sqerl_mysql_client).

-behaviour(sqerl_client).

-include_lib("emysql/include/emysql.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/1]).

%% sqerl_client callbacks
-export([init/1,
         exec_prepared_statement/3,
         exec_prepared_select/3]).

-record(state, {cn}).

start_link(Config) ->
    sqerl_client:start_link(?MODULE, Config).

exec_prepared_select(Name, Args, #state{cn=Cn}=State) ->
    Result = emysql_conn:execute(Cn, Name, Args),
    case Result of
        #result_packet{}=Result ->
            %% Unpack rows
            Rows = unpack_rows(Result),
            {{ok, Rows}, State};
        #error_packet{msg=Reason} ->
            {{error, Reason}, State}
    end.

exec_prepared_statement(Name, Args, #state{cn=Cn}=State) ->
    Result = emysql_conn:execute(Cn, Name, Args),
    case Result of
        #ok_packet{affected_rows=Count} ->
            {{ok, Count}, State};
        #error_packet{msg=Reason} ->
            {{error, Reason}, State}
    end.

init(Config) ->
    {host, Host} = lists:keyfind(host, 1, Config),
    {port, Port} = lists:keyfind(port, 1, Config),
    {user, User} = lists:keyfind(user, 1, Config),
    {pass, Pass} = lists:keyfind(pass, 1, Config),
    {db, Db} = lists:keyfind(db, 1, Config),
    {prepared_statement_source, Prepared} = lists:keyfind(prepared_statement_source, 1, Config),
    %% Need this hokey pool record to create a database connection
    PoolDescriptor = #pool{host=Host, port=Port, user=User, password=Pass,
                           database=Db, encoding=utf8},
    case catch emysql_conn:open_connection(PoolDescriptor) of
        {'EXIT', Error} ->
            {stop, Error};
        #emysql_connection{socket=Sock}=Connection ->
            %% Link to socket so if this process dies we clean up
            %% the socket
            erlang:link(Sock),
            erlang:process_flag(trap_exit, true),
            {ok, Statements} = file:consult(Prepared),
            ok = load_statements(Statements),
            {ok, #state{cn=Connection}}
    end.

%% Internal functions
load_statements([]) ->
    ok;
load_statements([{Name, SQL}|T]) ->
    case emysql:prepare(Name, SQL) of
        ok ->
            load_statements(T);
        Error ->
            Error
    end.

%% Converts contents of result_packet into our "standard"
%% representation of a list of proplists. In other words,
%% each row is converted into a proplist and then collected
%% up into a list containing all the converted rows for
%% a given query result.
unpack_rows(#result_packet{field_list=Fields, rows=Rows}) ->
    unpack_rows(Fields, Rows, []).

unpack_rows(_Fields, [], []) ->
    none;
unpack_rows(_Fields, [], Accum) ->
    lists:reverse(Accum);
unpack_rows(Fields, [Values|T], Accum) ->
    F = fun(Field, {Idx, Row}) ->
                {Idx + 1, [{Field#field.name, lists:nth(Idx, Values)}|Row]} end,
    {_, Row} = lists:foldl(F, {1, []}, Fields),
    unpack_rows(Fields, T, [lists:reverse(Row)|Accum]).
