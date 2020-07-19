-module(lynkia_mapreduce_adapter_csv).
-export([
    get_pairs/3
]).

% @pre -
% @post -
get_pairs(Entries, _Options, Callback) ->
    Separator = ";",
    Parser = fun(_, Column) -> Column end,
    Pairs = lists:flatmap(fun({Path, Map}) ->
        Tuples = file_reader:read_csv(Path, Separator, Parser),
        lists:flatmap(fun(Tuple) ->
            erlang:apply(Map, [Tuple])
        end, Tuples)
    end, Entries),
    erlang:apply(Callback, [Pairs]).