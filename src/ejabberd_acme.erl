-module (ejabberd_acme).

-export([ scenario/3
        , scenario0/1
        , directory/1

        , get_account/3
        , new_account/4
        , update_account/4
        , delete_account/3
        % , key_roll_over/5

        , new_authz/4
        % , get_authz/3
        ]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(REQUEST_TIMEOUT, 5000). % 5 seconds.


-type nonce() :: string().
-type url() :: string().
-type proplist() :: [{_, _}].
-type jws() :: map().
-type handle_resp_fun() :: fun(({ok, proplist(), proplist()}) -> {ok, _, nonce()}).

-spec directory(url()) ->
  {ok, map(), nonce()} | {error, _}.
directory(Url) ->
  Options = [],
  HttpOptions = [{timeout, ?REQUEST_TIMEOUT}],
  case httpc:request(get, {Url, []}, HttpOptions, Options) of
    {ok, {{_, Code, _}, Head, Body}} when Code >= 200, Code =< 299 ->
      case decode(Body) of
        {ok, Directories} ->
          StrDirectories = [{bitstring_to_list(X), bitstring_to_list(Y)} ||
                              {X,Y} <- Directories],
          Nonce = get_nonce(Head),
          %% Return Map of Directories
          NewDirs = maps:from_list(StrDirectories),
          {ok, NewDirs, Nonce};
        {error, Reason} ->
          ?ERROR_MSG("Problem decoding: ~s", [Body]),
          {error, Reason}
      end;
    Error ->
      failed_http_request(Error, Url)
  end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Account Handling
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec new_account(url(), jose_jwk:key(), proplist(), nonce()) ->
  {ok, {url(), proplist()}, nonce()} | {error, _}.
new_account(Url, PrivateKey, Req, Nonce) ->
  %% Make the request body
  EJson = {[{ <<"resource">>, <<"new-reg">>}] ++ Req},
  prepare_post_request(Url, PrivateKey, EJson, Nonce, fun get_response_tos/1).

-spec update_account(url(), jose_jwk:key(), proplist(), nonce()) ->
  {ok, proplist(), nonce()} | {error, _}.
update_account(Url, PrivateKey, Req, Nonce) ->
  %% Make the request body
  EJson = {[{ <<"resource">>, <<"reg">>}] ++ Req},
  prepare_post_request(Url, PrivateKey, EJson, Nonce, fun get_response/1).

-spec get_account(url(), jose_jwk:key(), nonce()) ->
  {ok, {url(), proplist()}, nonce()} | {error, _}.
get_account(Url, PrivateKey, Nonce) ->
  %% Make the request body
  EJson = {[{<<"resource">>, <<"reg">>}]},
  prepare_post_request(Url, PrivateKey, EJson, Nonce, fun get_response_tos/1).

-spec delete_account(url(), jose_jwk:key(), nonce()) ->
  {ok, proplist(), nonce()} | {error, _}.
delete_account(Url, PrivateKey, Nonce) ->
  EJson = {
    [ {<<"resource">>, <<"reg">>}
    , {<<"status">>, <<"deactivated">>}
    ]},
  prepare_post_request(Url, PrivateKey, EJson, Nonce, fun get_response/1).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Authorization Handling
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec new_authz(url(), jose_jwk:key(), proplist(), nonce()) ->
  {ok, proplist(), nonce()} | {error, _}.
new_authz(Url, PrivateKey, Req, Nonce) ->
  EJson = {[{<<"resource">>, <<"new-authz">>}] ++ Req},
  prepare_post_request(Url, PrivateKey, EJson, Nonce, fun get_response/1).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Useful funs
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_nonce(proplist()) -> nonce() | 'none'.
get_nonce(Head) ->
  case proplists:lookup("replay-nonce", Head) of
    {"replay-nonce", Nonce} -> Nonce;
    none -> none
  end.

%% Very bad way to extract this
%% TODO: Find a better way
-spec get_tos(proplist()) -> url() | 'none'.
get_tos(Head) ->
  try
    [{_, Link}] = [{K, V} || {K, V} <- Head,
        K =:= "link" andalso lists:suffix("\"terms-of-service\"", V)],
    [Link1, _] = string:tokens(Link, ";"),
    Link2 = string:strip(Link1, left, $<),
    string:strip(Link2, right, $>)
  catch
    _:_ ->
      none
  end.


-spec make_post_request(url(), bitstring()) ->
  {ok, proplist(), proplist()} | {error, _}.
make_post_request(Url, ReqBody) ->
  Options = [],
  HttpOptions = [{timeout, ?REQUEST_TIMEOUT}],
  case httpc:request(post,
      {Url, [], "application/jose+json", ReqBody}, HttpOptions, Options) of
    {ok, {{_, Code, _}, Head, Body}} when Code >= 200, Code =< 299 ->
      case decode(Body) of
        {ok, Return} ->
          {ok, Head, Return};
        {error, Reason} ->
          ?ERROR_MSG("Problem decoding: ~s", [Body]),
          {error, Reason}
      end;
    Error ->
      failed_http_request(Error, Url)
  end.

-spec prepare_post_request(url(), jose_jwk:key(), jiffy:json_value(), 
  nonce(), handle_resp_fun()) -> {ok, _, nonce()} | {error, _}.
prepare_post_request(Url, PrivateKey, EJson, Nonce, HandleRespFun) ->
  case encode(EJson) of
    {ok, ReqBody} ->
      FinalBody = sign_encode_json_jose(PrivateKey, ReqBody, Nonce),
      case make_post_request(Url, FinalBody) of
        {ok, Head, Return} ->
          HandleRespFun({ok, Head, Return});
        Error ->
          Error
      end;
    {error, Reason} ->
      ?ERROR_MSG("Error: ~p when encoding: ~p", [Reason, EJson]),
      {error, Reason}
  end.

-spec sign_json_jose(jose_jwk:key(), string()) -> jws().
sign_json_jose(Key, Json) ->
    PubKey = jose_jwk:to_public(Key),
    {_, BinaryPubKey} = jose_jwk:to_binary(PubKey),
    PubKeyJson = jiffy:decode(BinaryPubKey),
    % Jws object containing the algorithm
    %% TODO: Dont hardcode the alg
    JwsObj = jose_jws:from(
      #{ <<"alg">> => <<"ES256">>
       % , <<"b64">> => true
       , <<"jwk">> => PubKeyJson
       }),
    %% Signed Message
    jose_jws:sign(Key, Json, JwsObj).

-spec sign_json_jose(jose_jwk:key(), string(), nonce()) -> jws().
sign_json_jose(Key, Json, Nonce) ->
    % Generate a public key
    PubKey = jose_jwk:to_public(Key),
    % ?INFO_MSG("Key: ~p", [Key]),
    {_, BinaryPubKey} = jose_jwk:to_binary(PubKey),
    % ?INFO_MSG("Key Record: ~p", [jose_jwk:to_map(Key)]),
    PubKeyJson = jiffy:decode(BinaryPubKey),
    % Jws object containing the algorithm
    %% TODO: Dont hardcode the alg
    JwsObj = jose_jws:from(
      #{ <<"alg">> => <<"ES256">>
       % , <<"b64">> => true
       , <<"jwk">> => PubKeyJson
       , <<"nonce">> => list_to_bitstring(Nonce)
       }),
    %% Signed Message
    jose_jws:sign(Key, Json, JwsObj).

-spec sign_encode_json_jose(jose_jwk:key(), string(), nonce()) -> bitstring().
sign_encode_json_jose(Key, Json, Nonce) ->
  {_, Signed} = sign_json_jose(Key, Json, Nonce),
  %% This depends on jose library, so we can consider it safe
  jiffy:encode(Signed).

encode(EJson) ->
  try
    {ok, jiffy:encode(EJson)}
  catch
    _:Reason ->
      {error, Reason}
  end.

decode(Json) ->
  try
    {Result} = jiffy:decode(Json),
    {ok, Result}
  catch
    _:Reason ->
      {error, Reason}
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Handle Response Functions
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_response({ok, proplist(), proplist()}) -> {ok, proplist(), nonce()}.
get_response({ok, Head, Return}) ->
  NewNonce = get_nonce(Head),
  {ok, Return, NewNonce}.

-spec get_response_tos({ok, proplist(), proplist()}) -> {ok, {url(), proplist()}, nonce()}.
get_response_tos({ok, Head, Return}) ->
  TOSUrl = get_tos(Head),
  NewNonce = get_nonce(Head),
  {ok, {TOSUrl, Return}, NewNonce}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Handle Failed HTTP Requests
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec failed_http_request({ok, _} | {error, _}, url()) -> {error, _}.
failed_http_request({ok, {{_, Code, _}, _Head, Body}}, Url) ->
  ?ERROR_MSG("Got unexpected status code from <~s>: ~B, Body: ~s",
    [Url, Code, Body]),
  {error, unexpected_code};
failed_http_request({error, Reason}, Url) ->
  ?ERROR_MSG("Error making a request to <~s>: ~p",
    [Url, Reason]),
  {error, Reason}.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Debugging Funcs -- They are only used for the development phase
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% A typical acme workflow
scenario(CAUrl, AccId, PrivateKey) ->
  DirURL = CAUrl ++ "/directory",
  {ok, Dirs, Nonce0} = directory(DirURL),

  AccURL = CAUrl ++ "/acme/reg/" ++ AccId,
  {ok, {_TOS, Account}, Nonce1} = get_account(AccURL, PrivateKey, Nonce0),

  #{"new-authz" := NewAuthz} = Dirs,
  Req =
    [ { <<"identifier">>, {
      [ {<<"type">>, <<"dns">>}
      , {<<"value">>, <<"my-acme-test-ejabberd.com">>}
      ] }}
    , {<<"existing">>, <<"accept">>}
    ],
  {ok, Authz, Nonce2} = new_authz(NewAuthz, PrivateKey, Req, Nonce1),

  {Account, Authz, PrivateKey}.


new_user_scenario(CAUrl) ->
  PrivateKey = generate_key(),

  DirURL = CAUrl ++ "/directory",
  {ok, Dirs, Nonce0} = directory(DirURL),
  ?INFO_MSG("Directories: ~p", [Dirs]),

  #{"new-reg" := NewAccURL} = Dirs,
  Req0 = [{ <<"contact">>, [<<"mailto:cert-example-admin@example2.com">>]}],
  {ok, {TOS, Account}, Nonce1} = new_account(NewAccURL, PrivateKey, Req0, Nonce0),

  {_, AccId} = proplists:lookup(<<"id">>, Account),
  AccURL = CAUrl ++ "/acme/reg/" ++ integer_to_list(AccId),
  {ok, {_TOS, Account1}, Nonce2} = get_account(AccURL, PrivateKey, Nonce1),
  ?INFO_MSG("Old account: ~p~n", [Account1]),

  Req1 = [{ <<"agreement">>, list_to_bitstring(TOS)}],
  {ok, Account2, Nonce3} = update_account(AccURL, PrivateKey, Req1, Nonce2),

  %%
  %% Delete account
  %%

  {ok, Account3, Nonce4} = delete_account(AccURL, PrivateKey, Nonce3),
  {ok, {_TOS, Account4}, Nonce5} = get_account(AccURL, PrivateKey, Nonce4),
  ?INFO_MSG("New account: ~p~n", [Account4]),

  % NewKey = generate_key(),
  % KeyChangeUrl = CAUrl ++ "/acme/key-change/",
  % {ok, Account3, Nonce4} = key_roll_over(KeyChangeUrl, AccURL, PrivateKey, NewKey, Nonce3),
  % ?INFO_MSG("Changed key: ~p~n", [Account3]),

  % {ok, {_TOS, Account4}, Nonce5} = get_account(AccURL, NewKey, Nonce4),
  % ?INFO_MSG("New account:~p~n", [Account4]),

  {Account4, PrivateKey}.

generate_key() ->
  jose_jwk:generate_key({ec, secp256r1}).

%% Just a test
scenario0(KeyFile) ->
  PrivateKey = jose_jwk:from_file(KeyFile),
  % scenario("http://localhost:4000", "2", PrivateKey).
  new_user_scenario("http://localhost:4000").

% ejabberd_acme:scenario0("/home/konstantinos/Desktop/Programming/ejabberd/private_key_temporary").
