-module(chef_req).

-export([request/3,
         request/4,
         make_config/3,
         clone_config/3,

         make_client/3,
         delete_client/3,
         remove_client_from_group/4,

         start_apps/0]).

-include("chef_req.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("chef_common/include/ej.hrl").
-include_lib("chef_common/include/chef_rest_client.hrl").

-define(gv(K, L), proplists:get_value(K, L)).

-export([main/1]).

main([]) ->
    Msg = "chef_req PATH\n\n"
        "Make Chef API requests\n"
        "Uses ./chef_req.config\n"
        "PATH example: /organizations/your-org/roles\n",
    io:format(Msg);
main([Path]) ->
    ok = start_apps(),
    %% FIXME: for now, config file location is  hard coded
    ReqConfig = load_config("./chef_req.config"),

    {ok, Code, Head, Body} = request(get, Path, ReqConfig),
    io:format(standard_error, "~s ~s~n", [Code, Path]),
    io:format(standard_error, "~s~n", ["----------------"]),
    [ io:format(standard_error, "~s:~s~n", [K, V])
      || {K, V} <- Head ],
    io:format(standard_error, "~s~n", ["----------------"]),
    io:format("~s~n", [Body]).

request(Method, Path, ReqConfig) ->
    request(Method, Path, [], ReqConfig).

request(Method, Path, Body,
        #req_config{api_root = ApiRoot, name = Name, private_key = Private}) ->
    {Url, Headers} = make_headers(method_to_bin(Method), ApiRoot, Path,
                                  Name, Private, Body),
    ibrowse:send_req(Url, Headers, Method, Body,
                     [{ssl_options, []}, {response_format, binary}]).

make_config(ApiRoot, Name, {key, Key}) ->
    Private = chef_authn:extract_private_key(Key),
    #req_config{api_root = ApiRoot, name = Name, private_key = Private};
make_config(ApiRoot, Name, KeyPath) ->
    {ok, PBin} = file:read_file(KeyPath),
    make_config(ApiRoot, Name, {key, PBin}).

make_client(Org, ClientName, Config) ->
    Path = "/organizations/" ++ Org ++ "/clients",
    ReqBody = iolist_to_binary([<<"{\"name\":\"">>, ClientName, <<"\"}">>]),
    {ok, "201", _H, Body} = request(post, Path, ReqBody, Config),
    Client = ejson:decode(Body),
    ClientConfig = clone_config(Config, ClientName,
                                ej:get({<<"private_key">>}, Client)),
    ClientConfig.

delete_client(Org, ClientName, Config) ->
    Path = "/organizations/" ++ Org ++ "/clients/" ++ ClientName,
    {ok, Code, _H, _Body} = request(delete, Path, Config),
    if
        Code =:= "200" orelse Code =:= "404" -> ok;
        true -> {error, Code}
    end.

remove_client_from_group(Org, ClientName, GroupName, Config) ->
    Path = "/organizations/" ++ Org ++ "/groups/" ++ GroupName,
    {ok, "200", _H0, Body1} = request(get, Path, Config),
    Group0 = ejson:decode(Body1),
    Actors = ej:get({<<"actors">>}, Group0),
    NewActors = lists:delete(ensure_bin(ClientName), Actors),
    Group1 = ej:set({<<"actors">>}, Group0, NewActors),
    PutGroup = make_group_for_put(Group1),
    {ok, "200", _H1, _Body2} = request(put, Path, ejson:encode(PutGroup), Config),
    ok.

make_group_for_put(Group) ->
    {[{<<"groupname">>, ej:get({<<"groupname">>}, Group)},
      {<<"orgname">>, ej:get({<<"orgname">>}, Group)},
      {<<"actors">>,
       %% The asymmetry is impressive here.  We GET a flat structure
       %% of actors which consists of both users and clients.  When we
       %% PUT we must specify both users and clients.  I believe that
       %% items of the wrong type are ignored so the simple
       %% duplication approach should be sufficient.
       {[{<<"users">>, ej:get({<<"actors">>}, Group)},
         {<<"clients">>, ej:get({<<"actors">>}, Group)},
         {<<"groups">>, ej:get({<<"groups">>}, Group)}]}
       }]}.

clone_config(#req_config{}=Config, Name, Key) ->
    Private = chef_authn:extract_private_key(Key),
    Config#req_config{name = Name, private_key = Private}.

load_config(Path) ->
    {ok, Config} = file:consult(Path),
    PrivatePath  = ?gv(private_key, Config),
    ApiRoot = ?gv(api_root, Config),
    Name = ?gv(client_name, Config),
    make_config(ApiRoot, Name, PrivatePath).

start_apps() ->
    [ ensure_started(M) || M <- [crypto, public_key, ssl] ],
    case ibrowse:start() of
        {ok, _} -> ok;
        {error,{already_started, _}} -> ok
    end,
    ok.

ensure_started(M) ->
    case application:start(M) of
        ok ->
            ok;
        {error,{already_started,_}} ->
            ok;
        Error ->
            Error
    end.

method_to_bin(get) ->
    <<"GET">>;
method_to_bin(put) ->
    <<"PUT">>;
method_to_bin(post) ->
    <<"POST">>;
method_to_bin(delete) ->
    <<"DELETE">>;
method_to_bin(head) ->
    <<"HEAD">>.

make_headers(Method, ApiRoot, Path, Name, Private, Body) ->
    Client = chef_rest_client:make_chef_rest_client(ApiRoot, Name, Private),
    {Url, Headers0} = chef_rest_client:generate_signed_headers(Client, Path,
                                                               Method, Body),
    Headers1 = header_for_body(Body, Headers0),
    {Url, [{"Accept", "application/json"},
           {"X-CHEF-VERSION", ?CHEF_VERSION} | Headers1]}.

header_for_body([], Headers) ->
    Headers;
header_for_body(_, Headers) ->
    [{"content-type", "application/json"}|Headers].

ensure_bin(L) when is_list(L) ->
    list_to_binary(L);
ensure_bin(B) when is_binary(B) ->
    B.

