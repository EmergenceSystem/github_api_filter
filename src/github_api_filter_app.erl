%%%-------------------------------------------------------------------
%%% @doc GitHub API search filter.
%%%
%%% Searches GitHub repositories, code, issues, and users matching
%%% the query and returns them as embryo maps.
%%% Uses GITHUB_API env var as Bearer token if available.
%%% @end
%%%-------------------------------------------------------------------
-module(github_api_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1]).

-define(GITHUB_API_URL, "https://api.github.com/search/").

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_filter(github_filter, ?MODULE).

stop(_State) ->
    em_filter:stop_filter(github_filter).

%%====================================================================
%% Filter handler — returns a list of embryo maps
%%====================================================================

handle(Body) when is_binary(Body) ->
    generate_embryo_list(Body);
handle(_) ->
    [].

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    Types     = ["repositories", "code", "issues", "users"],
    StartTime = erlang:system_time(millisecond),
    search_all_types(Types, Value, StartTime, Timeout * 1000, []).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>,   Map, <<"">>)),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

search_all_types([], _Query, _Start, _Timeout, Acc) ->
    lists:reverse(Acc);
search_all_types([Type | Rest], Query, Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            Results = search_github_type(Type, Query, Timeout div 1000),
            search_all_types(Rest, Query, Start, Timeout, Results ++ Acc)
    end.

search_github_type(Type, Query, TimeoutSecs) ->
    Url     = lists:concat([?GITHUB_API_URL, Type,
                             "?q=", uri_string:quote(Query), "&per_page=30"]),
    Headers = build_headers(),
    case httpc:request(get, {Url, Headers},
                       [{timeout, TimeoutSecs * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_response(Body, Type);
        _ ->
            []
    end.

build_headers() ->
    Base = [{"User-Agent",           "Emergence-GitHub-Filter"},
            {"Accept",               "application/vnd.github+json"},
            {"X-GitHub-Api-Version", "2022-11-28"}],
    case os:getenv("GITHUB_API") of
        false  -> Base;
        ApiKey -> [{"Authorization", "Bearer " ++ ApiKey} | Base]
    end.

%%--------------------------------------------------------------------
%% Response parsing
%%--------------------------------------------------------------------

parse_response(JsonData, Type) ->
    try json:decode(JsonData) of
        #{<<"items">> := Items} when is_list(Items) ->
            lists:filtermap(fun(Item) -> process_item(Item, Type) end, Items);
        _ -> []
    catch
        _:_ -> []
    end.

process_item(Item, "repositories") ->
    case {maps:get(<<"html_url">>,    Item, undefined),
          maps:get(<<"full_name">>,   Item, undefined)} of
        {Url, Name} when is_binary(Url), is_binary(Name) ->
            Desc  = case maps:get(<<"description">>, Item, undefined) of
                D when is_binary(D) -> <<Name/binary, " - ", D/binary>>;
                _                   -> Name
            end,
            Stars = case maps:get(<<"stargazers_count">>, Item, 0) of
                N when is_integer(N) -> N;
                _                    -> 0
            end,
            Lang  = case maps:get(<<"language">>, Item, <<"Unknown">>) of
                L when is_binary(L) -> L;
                _                   -> <<"Unknown">>
            end,
            Resume = unicode:characters_to_binary(
                io_lib:format("~ts [⭐ ~p | ~ts]",
                    [binary_to_list(Desc), Stars, binary_to_list(Lang)])),
            {true, embryo(Url, Resume)};
        _ -> false
    end;

process_item(Item, "code") ->
    case {maps:get(<<"html_url">>, Item, undefined),
          maps:get(<<"path">>,     Item, undefined)} of
        {Url, Path} when is_binary(Url), is_binary(Path) ->
            Repo = case maps:get(<<"repository">>, Item, undefined) of
                R when is_map(R) -> maps:get(<<"full_name">>, R, <<"Unknown">>);
                _                -> <<"Unknown">>
            end,
            Resume = <<Path/binary, " in ", Repo/binary>>,
            {true, embryo(Url, Resume)};
        _ -> false
    end;

process_item(Item, "issues") ->
    case {maps:get(<<"html_url">>, Item, undefined),
          maps:get(<<"title">>,    Item, undefined)} of
        {Url, Title} when is_binary(Url), is_binary(Title) ->
            Number  = maps:get(<<"number">>, Item, 0),
            State   = maps:get(<<"state">>,  Item, <<"unknown">>),
            RepoUrl = maps:get(<<"repository_url">>, Item, <<"">>),
            Repo    = extract_repo_name(RepoUrl),
            Resume  = unicode:characters_to_binary(
                io_lib:format("#~p: ~ts [~ts] - ~ts",
                    [Number, binary_to_list(Title),
                     binary_to_list(State), binary_to_list(Repo)])),
            {true, embryo(Url, Resume)};
        _ -> false
    end;

process_item(Item, "users") ->
    case {maps:get(<<"html_url">>, Item, undefined),
          maps:get(<<"login">>,    Item, undefined)} of
        {Url, Login} when is_binary(Url), is_binary(Login) ->
            Type   = maps:get(<<"type">>, Item, <<"User">>),
            Resume = <<Login/binary, " (", Type/binary, ")">>,
            {true, embryo(Url, Resume)};
        _ -> false
    end;

process_item(_, _) -> false.

embryo(Url, Resume) ->
    #{<<"properties">> => #{<<"url">> => Url, <<"resume">> => Resume}}.

extract_repo_name(<<"https://api.github.com/repos/", Rest/binary>>) -> Rest;
extract_repo_name(_) -> <<"Unknown">>.
