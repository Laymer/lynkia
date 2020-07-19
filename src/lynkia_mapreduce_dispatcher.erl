-module(lynkia_mapreduce_dispatcher).
-include("lynkia.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    start/2,
    start/3
]).

% @pre -
% @post -
start(Pairs, Reduce) ->
    start(Pairs, Reduce, #options{
        max_round = 20,
        max_batch_size = 100,
        timeout = 5000
    }).

% @pre -
% @post -
start(Pairs, Reduce, Options) ->
    N = dispatch(Pairs, Reduce, Options),
    receive_all(#{
        jobs => N,
        accumulator => []
    }, Reduce, Options).

% @pre -
% @post -
receive_all(State, Reduce, Options) ->
    receive
        {add, Pairs} ->
            logger:info("[MAPREDUCE]: message=~p;pairs=~p~n", ["add", Pairs]),
            case State of
                #{jobs := N, accumulator := Acc} when N =< 1 ->
                    Result = add_pairs(Acc, Pairs),
                    logger:info("[MAPREDUCE]: message=~p;result=~p~n", ["add_last_batch", Result]),
                    {ok, Result};
                #{jobs := N, accumulator := Acc} ->
                    Result = add_pairs(Acc, Pairs),
                    logger:info("[MAPREDUCE]: message=~p;result=~p~n", ["add_batch", Result]),
                    receive_all(State#{
                        jobs := N - 1,
                        accumulator := Result
                    }, Reduce, Options)
            end;
        {split, Batch} when erlang:length(Batch) > 1 ->
            logger:info("[MAPREDUCE]: message=~p;batch=~p~n", ["split", Batch]),
            case State of
                #{jobs := N} ->
                    M = split_batch(Batch, Reduce),
                    receive_all(State#{
                        jobs := N - 1 + M
                    }, Reduce, Options)
            end;
        {split, _Batch} ->
            {error, "Could not divide a batch of length 1"};
        {error, Reason} ->
            logger:info("[MAPREDUCE]: message=~p;reason=~p~n", ["error", Reason]),
            {error, Reason}
    after 5000 ->
        case State of #{jobs := N} ->
            io:format("Remainging jobs=~p~n", [N])
        end,
        {error, no_activity}
    end.

% @pre -
% @post -
add_pairs(Acc, Pairs) when erlang:is_list(Pairs) ->
    Acc ++ lists:filter(fun(Pair) ->
        case Pair of
            {_, _} -> true;
            _ -> false
        end
    end, Pairs);
add_pairs(Acc, Pairs) ->
    add_pairs(Acc, [Pairs]).

% @pre -
% @post -
first_pass(Pairs, Reduce, Options) ->
    Limit = Options#options.max_batch_size - 1,
    lists:foldl(fun(Pair, {N, Orddict}) ->
        {Key, _} = Pair,
        case orddict:find(Key, Orddict) of
            {ok, Group} when erlang:length(Group) >= Limit ->
                Batch = [Pair|Group],
                start_reduction(Batch, Reduce),
                {N + 1, orddict:erase(Key, Orddict)};
            _ ->
                {N, orddict:append(Key, Pair, Orddict)}
        end
    end, {0, orddict:new()}, Pairs).

% @pre -
% @post -
form_batch(L1, L2, Batch, Options) ->
    case L1 of
        [] -> {Batch, L2};
        [H2|T2] ->
            {_, Pairs} = H2,
            case {
                erlang:length(Batch) + erlang:length(Pairs),
                Options#options.max_batch_size
            } of
                {N, M} when N > M ->
                    form_batch(T2, L2 ++ [H2], Batch, Options);
                {N, M} when N < M ->
                    form_batch(T2, L2, Batch ++ Pairs, Options);
                {_, _} ->
                    {Batch ++ Pairs, L2 ++ T2}
            end
    end.

% @pre -
% @post -
form_batches(L1, N, Reduce, Options) ->
    case form_batch(L1, [], [], Options) of
        {Batch, L2} ->
            start_reduction(Batch, Reduce),
            M = N + 1,
            case L2 of [_|_] ->
                form_batches(L2, M, Reduce, Options);
            _ -> M end
    end.

% @pre -
% @post -
second_pass(Groups, Reduce, Options) ->
    logger:info("[MAPREDUCE]: message=~p", ["second_pass"]),
    L = lists:sort(fun({_, P1}, {_, P2}) ->
        erlang:length(P1) > erlang:length(P2)
    end, Groups),
    form_batches(L, 0, Reduce, Options).

% @pre -
% @post -
group_pairs_per_key(Pairs) ->
    Groups = lists:foldl(fun(Pair, Orddict) ->
        case Pair of {Key, Value} ->
            orddict:append(Key, Value, Orddict)
        end
    end, orddict:new(), Pairs),
    orddict:to_list(Groups).

% @pre -
% @post -
reduce(Reduce) ->
    fun(Batch) ->
        Groups = group_pairs_per_key(Batch),
        lists:flatmap(fun({Key, Pairs}) ->
            erlang:apply(Reduce, [Key, Pairs])
        end, Groups)
    end.

% @pre -
% @post -
start_reduction(Batch, Reduce) ->
    Self = self(),
    lynkia_spawn:schedule(reduce(Reduce), [Batch], fun(Result) ->
        case Result of
            {ok, Pairs} ->
                % logger:info("[MAPREDUCE]: message=~p;pairs=~p~n", ["SR ok", Pairs]),
                Self ! {add, Pairs};
            {error, Reason} ->
                logger:info("[MAPREDUCE]: message=~p;error=~p~n", ["SR error", Reason]),
                Self ! {error, Reason};
            timeout ->
                logger:info("[MAPREDUCE]: message=~p~n", ["SR timeout"]),
                Self ! {split, Batch};
            killed ->
                logger:info("[MAPREDUCE]: message=~p~n", ["SR killed"]),
                Self ! {split, Batch}
        end
    end).

% @pre -
% @post -
dispatch(Pairs, Reduce, Options) ->
    {N, Groups} = first_pass(Pairs, Reduce, Options),
    M = second_pass(Groups, Reduce, Options),
    N + M.

% @pre -
% @post -
split_batch(Pairs, Reduce) ->
    N = erlang:length(Pairs),
    Options = #options{
        max_batch_size = erlang:ceil(N / 2)
    },
    dispatch(Pairs, Reduce, Options).

% ---------------------------------------------
% EUnit tests:
% ---------------------------------------------

-ifdef(TEST).

% First pass: Forming full batch

% @pre -
% @post -
first_pass_1_test() ->
    F = fun()-> ok end,
    Options = #options{
        max_batch_size = 2
    },
    Pairs = [{key1, value1}, {key2, value3}, {key1, value2}],
    {N, Orddict} = first_pass(Pairs, F, Options),
    ?assertEqual(N, 1),
    ?assertEqual(Orddict, orddict:from_list([
        {key2, [{key2, value3}]}
    ])),
    ok.

% @pre -
% @post -
first_pass_2_test() ->
    F = fun()-> ok end,
    Options = #options{
        max_batch_size = 2
    },
    Pairs = [
        {key1, value1}, {key1, value3}, {key1, value4}, {key1, value5}, {key1, value6},
        {key2, value7}, {key2, value8}, {key2, value9}, {key1, value2}
    ],
    {N, Orddict} = first_pass(Pairs, F, Options),
    ?assertEqual(N, 4),
    ?assertEqual(Orddict, orddict:from_list([
        {key2, [{key2, value9}]}
    ])),
    ok.

% Second pass: Merging remaining pairs

% @pre -
% @post -
second_pass_1_test() ->
    F = fun()-> ok end,
    Options = #options{
        max_batch_size = 2
    },
    Groups = [
        {key2, [{key2, value3}]},
        {key3, [{key3, value3}]}
    ],
    ?assertEqual(second_pass(Groups, F, Options), 1),
    ok.

% @pre -
% @post -
second_pass_2_test() ->
    F = fun() -> ok end,
    Options = #options{
        max_batch_size = 5
    },
    Groups = [
        {key2, [{key2, value3}, {key2, value4}, {key2, value5}]},
        {key3, [{key3, value3}]},
        {key1, [{key1, value3}, {key1, value4}]}
    ],
    ?assertEqual(second_pass(Groups, F, Options), 2),
    ok.

% @pre -
% @post -
second_pass_3_test() ->
    F = fun() -> ok end,
    Options = #options{
        max_batch_size = 5
    },
    Groups = [
        {key2, [{key2, value3}, {key2, value4}, {key2, value5}, {key2, value6}]},
        {key3, [{key3, value3}]},
        {key1, [{key1, value3}, {key1, value4}]}
    ],
    ?assertEqual(second_pass(Groups, F, Options), 2),
    ok.

% @pre -
% @post -
dispatch_test() ->
    F = fun() -> ok end,
    Options = #options{
        max_batch_size = 2
    },
    Pairs = [
        {key1, value1}, {key1, value3}, {key1, value4}, {key1, value5}, {key1, value6},
        {key2, value7}, {key2, value8}, {key2, value9}, {key1, value2}
    ],
    ?assertEqual(dispatch(Pairs, F, Options), 5),
    ok.

% @pre -
% @post -
split_batch_1_test() ->
    F = fun() -> ok end,
    Pairs = [{key1, value1}, {key1, value3}, {key1, value4}, {key1, value5}, {key1, value6}],
    ?assertEqual(split_batch(Pairs, F), 2),
    ok.

% @pre -
% @post -
split_batch_2_test() ->
    F = fun() -> ok end,
    Pairs = [{key4, value1}, {key2, value3}, {key2, value4}, {key2, value6}, {key4, value5}],
    ?assertEqual(split_batch(Pairs, F), 2),
    ok.

% @pre -
% @post -
add_pairs_test() ->
    ?assertEqual(add_pairs([], 2), []),
    ?assertEqual(add_pairs([], {2, 4}), [{2, 4}]),
    ?assertEqual(add_pairs([{2, 4}], {2, 4}), [{2, 4}, {2, 4}]),
    ?assertEqual(add_pairs([{2, 4}], [{2, 4}]), [{2, 4}, {2, 4}]),
    ?assertEqual(add_pairs([], {}), []),
    ?assertEqual(add_pairs([], [{}]), []),
    ?assertEqual(add_pairs([{2, 4}, {6, 8}], [{2, 4}, {10, 10}]), [{2, 4}, {6, 8}, {2, 4}, {10, 10}]),
    ok.

-endif.

% To launch the tests:
% rebar3 eunit --module=lynkia_mr_dispatcher