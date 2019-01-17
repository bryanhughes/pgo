%%% ---------------------------------------------------------------------------
%%% @author Tristan Sloughter <t@crashfast.com>
%%%
%%% @doc Postgres driver and pool for Erlang.
%%%
%%% This module provides functions for interacting with a pool and
%%  querying the database.
%%% @end
%%% ---------------------------------------------------------------------------
-module(pgo).

-export([start_pool/2,
         query/1,
         query/2,
         query/3,
         transaction/1,
         transaction/2,
         transaction/3,
         with_conn/2,
         checkout/1,
         checkout/2,
         checkin/2,
         break/1]).

-include("pgo_internal.hrl").

-export_type([result/0,
              error/0]).

-type result() :: #{command := atom(),
                    num_rows := integer(),
                    rows := list()} | {error, error()} | {error, any()}.

-type error() :: {pgo_error, #{error_field() => binary()}}.

-type pool() :: atom().

-type pool_opt() :: {size, integer()}
                  | {host, string()}
                  | {port, integer()}
                  | {user, string()}
                  | {password, string()}
                  | {database, string()}.
-type pool_config() :: [pool_opt()].

-type query_options() :: return_rows_as_maps | {return_rows_as_maps, boolean()}.
-type pool_options() :: queue | {queue, boolean()}.
-type options() :: #{pool => atom(),
                     pool_opts => [pool_options()],
                     query_opts => [query_options()]}.

%% @doc Starts connection pool as a child of pgo_sup.
-spec start_pool(pool(), pool_config()) -> {ok, pid()}.
start_pool(Name, PoolConfig) ->
    pgo_sup:start_child(Name, PoolConfig).

%% @equiv query(Query, [], #{})
-spec query(iodata()) -> result().
query(Query) ->
    query(Query, [], #{}).

%% @equiv query(Query, Params, #{})
-spec query(iodata(), list()) -> result().
query(Query, Params) ->
    query(Query, Params, #{}).

%% @doc Executes an extended query either on a Pool or a provided connection.
-spec query(iodata(), list(), options()) -> result().
query(Query, Params, Options) ->
    QueryOptions = maps:get(query_opts, Options, []),
    case get(pgo_transaction_connection) of
        undefined ->
            Pool = maps:get(pool, Options, default),
            PoolOptions = maps:get(pool_options, Options, []),
            case checkout(Pool, PoolOptions) of
                {ok, Ref, Conn} ->
                    try
                        pgo_handler:extended_query(Conn, Query, Params,
                                                   QueryOptions, #{queue_time => undefined})
                    after
                        checkin(Ref, Conn)
                    end;
                {error, _}=E ->
                    E
            end;
        Conn=#conn{pool=Pool} ->
            %% verify we aren't trying to run a query against another pool from a transaction
            case maps:get(pool, Options, Pool) of
                P when P =:= Pool ->
                    pgo_handler:extended_query(Conn, Query, Params, QueryOptions,
                                               #{queue_time => undefined});
                P ->
                    error({in_other_pool_transaction, P})
            end
    end.

%% @equiv transaction(default, Fun, [])
-spec transaction(fun(() -> any())) -> any() | {error, any()}.
transaction(Fun) ->
    transaction(default, Fun, []).

%% @equiv transaction(default, Fun, Options)
-spec transaction(fun(() -> any()), options()) -> any() | {error, any()}.
transaction(Fun, Options) when is_function(Fun) ->
    transaction(Fun, Options).

%% @doc Runs a function, passing it a connection, in a SQL transaction.
-spec transaction(pool(), fun(() -> any()), [pool_options()]) -> any() | {error, any()}.
transaction(Pool, Fun, Options) ->
    case get(pgo_transaction_connection) of
        undefined ->
            case checkout(Pool, Options) of
                {ok, Ref, Conn} ->
                    try
                        #{command := 'begin'} = pgo_handler:extended_query(Conn, "BEGIN", [], #{queue_time => undefined}),
                        put(pgo_transaction_connection, Conn),
                        Result = Fun(),
                        #{command := commit} = pgo_handler:extended_query(Conn, "COMMIT", [], #{queue_time => undefined}),
                        Result
                    catch
                        ?WITH_STACKTRACE(T, R, S)
                        pgo_handler:extended_query(Conn, "ROLLBACK", [], #{queue_time => undefined}),
                        erlang:raise(T, R, S)
                    after
                        checkin(Ref, Conn),
                        erase(pgo_transaction_connection)
                    end;
                {error, _}=E ->
                    E
            end;
        _Conn ->
            %% already in a transaction
            Fun()
    end.

with_conn(Conn, Fun) ->
    case get(pgo_transaction_connection) of
        undefined ->
            put(pgo_transaction_connection, Conn),
            try Fun()
            after
                erase(pgo_transaction_connection)
            end;
        OldConn ->
            try Fun()
            after
                put(pgo_transaction_connection, OldConn)
            end
    end.

%% @doc Returns a connection from the pool.
-spec checkout(atom()) -> {ok, pgo_pool:pool_ref(), pgo_pool:conn()} | {error, any()}.
checkout(Pool) ->
    pgo_pool:checkout(Pool, []).

-spec checkout(atom(), options()) -> {ok, pgo_pool:pool_ref(), pgo_pool:conn()} | {error, any()}.
checkout(Pool, Options) ->
    pgo_pool:checkout(Pool, Options).

%% @doc Return a checked out connection to its pool
-spec checkin(pgo_pool:pool_ref(), pgo_pool:conn()) -> ok.
checkin(Ref, Conn) ->
    pgo_pool:checkin(Ref, Conn, []).

%% @doc Disconnects the socket held by this reference.
-spec break(pgo_pool:conn()) -> ok.
break(Conn) ->
    pgo_connection:break(Conn).
