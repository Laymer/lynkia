%%%-----------------------------------------------------------------------------
%%% @doc This module contains helpers functions
%%%
%%% @author Julien Banken and Nicolas Xanthos
%%% @end
%%%-----------------------------------------------------------------------------
-module(lynkia_utils).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    join/1,
    myself/0,
    members/0,
    get_neighbors/0,
    repeat/2,
    query/1,
    now/0,
    choose/1
]).

%% @doc Return the name of the node.
myself() ->
    Manager = partisan_peer_service:manager(),
    case Manager:myself() of
        #{name := Name} -> Name
    end.

%% @doc Connect the node with the given node.
join(Name) ->
    partisan_peer_service:join(Name).

%% @doc Return the local view of the node.
%% The list will contain the name of the node
members() ->
    partisan_peer_service:members().

%% @doc Return the local view of the node.
%% The list will not contain the name of the node.
get_neighbors() ->
    case members() of {ok, Members} ->
        Name = myself(),
        Members -- [Name]
    end.

%% @doc Repeat the given callback function n times.
%% The callback function will take one parameter:
%% A number indicating how many times the function has already been executed
repeat(N, CallBack) ->
    repeat(0, N, CallBack).
repeat(K, N, CallBack) when N > 0 ->
    CallBack(K),
    repeat(K + 1, N - 1, CallBack);
repeat(_, N, _) when N =< 0 -> ok.

%% @doc Return the content of a CRDT variable
query(ID) ->
    {ok, Set} = lasp:query(ID) ,
    sets:to_list(Set).

%% @doc Return the current timestamp
now() ->
    erlang:system_time(millisecond).

%% @doc Choose one value at random from a list.
%% Each element will have the same probability of being selected
choose([]) -> error;
choose([_|_] = List) ->
    Length = erlang:length(List),
    N = rand:uniform(Length),
    {ok, lists:nth(N, List)}.

-ifdef(TEST).

choose_test() ->
    ?assertEqual(choose([]), error),
    ?assertEqual(choose([42]), {ok, 42}).

-endif.

% To launch the tests:
% rebar3 eunit --module=lynkia_utils