-module(github_api_filter_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% Handler callbacks
-export([handle/1]).

-define(GITHUB_API_URL, "https://api.github.com/search/").

%% Application behavior
start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(github_filter, ?MODULE, Port).

stop(_State) ->
    ok.

%% @doc Handle incoming requests from the filter server.
%% This function is called by em_filter_server through Wade.
%% @param Body The request body (JSON binary or string)
%% @return JSON response as binary or string
handle(Body) when is_binary(Body) ->
    handle(binary_to_list(Body));

handle(Body) when is_list(Body) ->
    EmbryoList = generate_embryo_list(list_to_binary(Body)),
    Response = #{embryo_list => EmbryoList},
    jsone:encode(Response);

handle(_) ->
    jsone:encode(#{error => <<"Invalid request body">>}).

generate_embryo_list(JsonBinary) ->
    case jsone:decode(JsonBinary, [{keys, atom}]) of
        Search when is_map(Search) ->
            Value = binary_to_list(maps:get(value, Search, <<"">>)),
            Timeout = list_to_integer(binary_to_list(maps:get(timeout, Search, <<"10">>))),

            %% Chercher dans tous les types de ressources GitHub
            SearchTypes = ["repositories", "code", "issues", "users"],
            
            StartTime = erlang:system_time(millisecond),
            TimeoutMs = Timeout * 1000,
            
            search_all_types(SearchTypes, Value, StartTime, TimeoutMs, []);
        {error, Reason} ->
            io:format("Error decoding JSON: ~p~n", [Reason]),
            []
    end.

search_all_types([], _Query, _StartTime, _Timeout, Acc) ->
    lists:reverse(Acc);
search_all_types([Type | Rest], Query, StartTime, Timeout, Acc) ->
    CurrentTime = erlang:system_time(millisecond),
    case CurrentTime - StartTime >= Timeout of
        true ->
            lists:reverse(Acc);
        false ->
            Results = search_github_type(Type, Query, Timeout div 1000),
            search_all_types(Rest, Query, StartTime, Timeout, Results ++ Acc)
    end.

search_github_type(Type, Query, TimeoutSecs) ->
    EncodedQuery = uri_string:quote(Query),
    Url = lists:concat([?GITHUB_API_URL, Type, "?q=", EncodedQuery, "&per_page=30"]),
    
    Headers = build_headers(),
    
    case httpc:request(get, {Url, Headers}, [{timeout, TimeoutSecs * 1000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            extract_items_from_response(Body, Type);
        {ok, {{_, StatusCode, _}, _, _}} when StatusCode == 401; StatusCode == 403 ->
            %% Authentication required or rate limited, skip silently
            [];
        {ok, {{_, StatusCode, _}, _, Body}} ->
            io:format("GitHub API returned status ~p for ~s: ~p~n", [StatusCode, Type, Body]),
            [];
        {error, Reason} ->
            io:format("Error fetching ~s results: ~p~n", [Type, Reason]),
            []
    end.

build_headers() ->
    BaseHeaders = [
        {"User-Agent", "Emergence-GitHub-Filter"},
        {"Accept", "application/vnd.github+json"},
        {"X-GitHub-Api-Version", "2022-11-28"}
    ],
    
    case os:getenv("GITHUB_API") of
        false ->
            BaseHeaders;
        ApiKey ->
            [{"Authorization", "Bearer " ++ ApiKey} | BaseHeaders]
    end.

extract_items_from_response(JsonData, Type) ->
    try jsone:decode(JsonData) of
        ParsedJson ->
            case maps:get(<<"items">>, ParsedJson, undefined) of
                Items when is_list(Items) ->
                    lists:filtermap(
                        fun(Item) -> process_item(Item, Type) end,
                        Items
                    );
                _ ->
                    []
            end
    catch
        error:Reason ->
            io:format("Failed to parse JSON response for ~s: ~p~n", [Type, Reason]),
            []
    end.

process_item(Item, "repositories") ->
    try
        Url = maps:get(<<"html_url">>, Item, undefined),
        Name = maps:get(<<"full_name">>, Item, undefined),
        
        case {Url, Name} of
            {U, N} when is_binary(U), is_binary(N) ->
                %% Gérer description qui peut être null
                Desc = maps:get(<<"description">>, Item, undefined),
                
                Resume = case Desc of
                    DescBin when is_binary(DescBin) ->
                        <<N/binary, " - ", DescBin/binary>>;
                    _ ->
                        N
                end,
                
                %% Gérer les cas où stargazers_count ou language peuvent être null
                Stars = case maps:get(<<"stargazers_count">>, Item, 0) of
                    Num when is_integer(Num) -> Num;
                    _ -> 0
                end,
                
                Language = case maps:get(<<"language">>, Item, <<"Unknown">>) of
                    L when is_binary(L) -> L;
                    _ -> <<"Unknown">>
                end,
                
                %% Convertir Resume en liste pour io_lib:format
                ResumeStr = binary_to_list(Resume),
                LanguageStr = binary_to_list(Language),
                
                Formatted = io_lib:format("~ts [⭐ ~p | ~ts]", [ResumeStr, Stars, LanguageStr]),
                FullResume = unicode:characters_to_binary(Formatted),
                
                {true, #{
                    properties => #{
                        <<"url">> => U,
                        <<"resume">> => FullResume,
                        <<"type">> => <<"repository">>
                    }
                }};
            _ ->
                false
        end
    catch
        Error:Reason:_Stack ->
            io:format("Error processing repository: ~p:~p~n", [Error, Reason]),
            false
    end;

process_item(Item, "code") ->
    case {maps:get(<<"html_url">>, Item, undefined),
          maps:get(<<"name">>, Item, undefined),
          maps:get(<<"path">>, Item, undefined)} of
        {Url, Name, Path} when is_binary(Url), is_binary(Name), is_binary(Path) ->
            Repo = case maps:get(<<"repository">>, Item, undefined) of
                RepoMap when is_map(RepoMap) ->
                    maps:get(<<"full_name">>, RepoMap, <<"Unknown">>);
                _ ->
                    <<"Unknown">>
            end,
            
            Resume = <<Path/binary, " in ", Repo/binary>>,
            
            {true, #{
                properties => #{
                    <<"url">> => Url,
                    <<"resume">> => Resume,
                    <<"type">> => <<"code">>
                }
            }};
        _ ->
            false
    end;

process_item(Item, "issues") ->
    case {maps:get(<<"html_url">>, Item, undefined),
          maps:get(<<"title">>, Item, undefined)} of
        {Url, Title} when is_binary(Url), is_binary(Title) ->
            Number = maps:get(<<"number">>, Item, 0),
            State = maps:get(<<"state">>, Item, <<"unknown">>),
            
            RepoUrl = maps:get(<<"repository_url">>, Item, <<"">>),
            RepoName = extract_repo_name(RepoUrl),
            
            ResumeStr = io_lib:format("#~p: ~ts [~ts] - ~ts", 
                                     [Number, binary_to_list(Title), 
                                      binary_to_list(State), binary_to_list(RepoName)]),
            Resume = unicode:characters_to_binary(ResumeStr),
            
            {true, #{
                properties => #{
                    <<"url">> => Url,
                    <<"resume">> => Resume,
                    <<"type">> => <<"issue">>
                }
            }};
        _ ->
            false
    end;

process_item(Item, "users") ->
    case {maps:get(<<"html_url">>, Item, undefined),
          maps:get(<<"login">>, Item, undefined)} of
        {Url, Login} when is_binary(Url), is_binary(Login) ->
            Type = maps:get(<<"type">>, Item, <<"User">>),
            
            Resume = <<Login/binary, " (", Type/binary, ")">>,
            
            {true, #{
                properties => #{
                    <<"url">> => Url,
                    <<"resume">> => Resume,
                    <<"type">> => <<"user">>
                }
            }};
        _ ->
            false
    end;

process_item(_, _) ->
    false.

%% Helper to extract repository name from repository_url
extract_repo_name(<<"https://api.github.com/repos/", Rest/binary>>) ->
    Rest;
extract_repo_name(_) ->
    <<"Unknown">>.
