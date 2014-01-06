%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% Copyright 2013 Chef Software, Inc. All Rights Reserved.
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
%% @doc chef_keygen_cache Precreates RSA key pairs and servers them when you ask.
%%
%% chef_keygen_cache is a gen_server that keeps a configurable number of RSA key pairs on
%% hand for fast delivery. There is a throttled mechanism (to avoid hogging CPU) to
%% replinish the key cache when it drops below the desired size. If you request a key when
%% the cache is empty, the atom `keygen_timeout' is returned immediately.
%%
%% You can control the behavior of the key cache using the following app config keys:
%% <ul>
%% <li>keygen_size: Size in bits of the RSA keys to generate. Defaults to 2048. Mostly used
%% to speed up testing.</li>
%% <li>keygen_cache_size: The number of keys to store in the cache</li>
%% <li>keygen_start_size: The number of keys that must be available in the cache before
%% completing startup and accepting requests. Cache startup blocks until `keygen_start_size'
%% keys are available in the cache.</li>
%% <li>keygen_timeout: Time allowed for the external key generation command (openssl). A
%% timeout atom is returned if the command takes longer than `Timeout' milliseconds. This
%% value is also used to bound the time allowed for the cache gen_server to respond to key
%% request calls</li>
%% <li>keygen_cache_workers: The number of workers available to generate key pairs. This
%% should never be larger than the number of logical CPUs. Defaults to larger of 1 and half
%% the number of logical processors as reported by `erlang:system_info(logical_processors)'
%% </li>
%% </ul>

-module(chef_keygen_cache).

-behaviour(gen_server).

%% API
-export([
         get_key_pair/0,
         start_link/0,
         status/0,
         stop/0,
         update_config/0
        ]).

%% gen_server callbacks
-export([
         code_change/3,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         init/1,
         terminate/2
        ]).

-include_lib("public_key/include/public_key.hrl").
-include("chef_authn.hrl").
-include("chef_keygen.hrl").

-define(SERVER, ?MODULE).


-record(state, {keys = [],
                max = ?DEFAULT_CACHE_SIZE,
                avail_workers = 1,
                inflight = []
               }).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

stop() ->
    gen_server:call(?SERVER, stop).

%% @doc Retrieve an RSA key pair from the cache.
%%
%% The return value is a tuple of the form `{PublicKey, PrivateKey}' where each element is a
%% binary containing the PEM encoded key. If no keys are available in the cache or if the
%% cache takes longer than the timeout value specified in app config `{chef_authn,
%% kegen_timeout, Timeout}', then the atom `keygen_timeout' is returned.
-spec get_key_pair() -> {PublicKey :: binary(), PrivateKey :: binary() } | keygen_timeout.
get_key_pair() ->
    Timeout = envy:get(chef_authn, keygen_timeout, ?DEFAULT_KEY_TIMEOUT, integer),
    case call_with_timeout(get_key_pair, Timeout) of
        cache_empty ->
            error_logger:error_report({chef_keygen_cache, empty}),
            keygen_timeout;
        #key_pair{} = KeyPair ->
            export_key_pair(KeyPair);
        timeout ->
            error_logger:warning_report({chef_keygen_cache, gen_server_timeout}),
            keygen_timeout
    end.

call_with_timeout(Msg, Timeout) ->
    try
        gen_server:call(?SERVER, Msg, Timeout)
    catch
        exit:{timeout, {gen_server, call, _}} ->
            timeout
    end.

%% @doc Return a proplist of status information about the state of the key cache.
-spec status() -> [{atom(), _}].
status() ->
    gen_server:call(?SERVER, status).

%% @doc Instruct the cache to reread app config values.
-spec update_config() -> ok.
update_config() ->
    gen_server:call(?SERVER, update_config).

init([]) ->
    {StartSize, State} = process_config(#state{keys = []}),

    {ok, StartState} = receive_key_loop(StartSize, async_refill(State)),
    {ok, StartState}.

receive_key_loop(0, State) ->
    {ok, State};
receive_key_loop(N, #state{keys = Keys} = State) ->
    receive
        #key_pair{} = KeyPair ->
            NewState = State#state{keys = [KeyPair | Keys]},
            receive_key_loop(N - 1, NewState);
        keygen_timeout ->
            receive_key_loop(N, State);
        {'DOWN', _MRef, process, Pid, Reason} ->
            NewState = handle_worker_down(Pid, Reason, State),
            receive_key_loop(N, async_refill(NewState))
    end.

process_config(State) ->
    StartSize0 = envy:get(chef_authn, keygen_start_size, 0, integer),
    Max = envy:get(chef_authn, keygen_cache_size, ?DEFAULT_CACHE_SIZE, integer),
    StartSize = normalize_start_size(StartSize0, Max),
    Workers = envy:get(chef_authn, keygen_cache_workers, default_worker_count(), integer),
    error_logger:info_msg("chef_keygen_cache configured size:~p start_size:~p avail_workers:~p",
                          [Max, StartSize, Workers]),
    {StartSize, State#state{max = Max, avail_workers = Workers}}.

normalize_start_size(StartSize, Max) when StartSize >= 0, StartSize =< Max ->
    StartSize;
normalize_start_size(StartSize, Max) ->
    Reason = {invalid_config,
              {chef_authn, [{keygen_start_size, StartSize},
                            {keygen_cache_size, Max}]}},
    error_logger:error_report(Reason),
    erlang:error(Reason).

%% If not configured, default to allowing up to half of available cores to be used for
%% keygen workers.
default_worker_count() ->
    %% docs say this can return 'unknown', but dialyzer complains.
    Cores = erlang:system_info(logical_processors),
    erlang:max(Cores div 2, 1).

handle_call(get_key_pair, _From, #state{keys = [KeyPair|Rest]} = State) ->
    State1 = State#state{keys = Rest},
    {reply, KeyPair, async_refill(State1)};
handle_call(get_key_pair, _From, #state{keys = []} = State) ->
    {reply, cache_empty, async_refill(State)};
handle_call(update_config, _From, State) ->
    {_StartSize, NewState} = process_config(State),
    {reply, ok, NewState};
handle_call(status, _From, State) ->
    #state{keys = Keys, max = Max,
           avail_workers = Avail, inflight = Inflight} = State,
    Ans = [{keys, length(Keys)}, {max, Max},
           {inflight, Inflight}, {avail_workers, Avail}],
    {reply, Ans, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(kill_workers_for_test, _From, #state{inflight = Inflight} = State) ->
    [ erlang:exit(P, kill) || P <- Inflight ],
    {reply, {killed, Inflight}, State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(keygen_timeout, State) ->
    error_logger:warning_report({chef_keygen_cache, keygen_timeout}),
    {noreply, State};
handle_info(#key_pair{} = KeyPair,
            #state{keys = Keys,
                   max = Max} = State) when length(Keys) < Max ->
    %% with the guard, we ignore key addition messages if we're full
    %% updating avail_workers handled by receiving 'DOWN' from monitor
    error_logger:info_report({chef_keygen_cache, received_key}),
    NewKeys = [KeyPair | Keys],
    NewState = State#state{keys = NewKeys},
    {noreply, NewState};
handle_info({'DOWN', _MRef, process, Pid, Reason}, State) ->
    NewState = handle_worker_down(Pid, Reason, State),
    {noreply, async_refill(NewState)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% If WorkerPid is in our inflight list, remove it from inflight and increment available
%% worker count. Log reason if worker died abnormally. If WorkerPid is not in inflight list,
%% ignore it.
handle_worker_down(WorkerPid, Reason, #state{avail_workers = Avail,
                                             inflight = Inflight} = State) ->
    %% We'll either remove 1 or 0
    {RemovedCount, NewInflight} = lists:foldl(
                                    fun(APid, {0, Acc}) when WorkerPid =:= APid ->
                                            log_non_normal(WorkerPid, Reason),
                                            %% remove APid from inflight list
                                            {1, Acc};
                                       (APid, {X, Acc}) ->
                                            {X, [APid | Acc]}
                                    end, {0, []}, Inflight),
    State#state{avail_workers = Avail + RemovedCount, inflight = NewInflight}.

async_refill(State) ->
    async_refill_in(State).

async_refill_in(#state{avail_workers = 0} = State) ->
    State;
async_refill_in(#state{keys = Keys, max = Max} = State) when length(Keys) == Max ->
    State;
async_refill_in(#state{avail_workers = N,
                       keys = Keys, max = Max,
                       inflight = Inflight} = State) ->
    Self = self(),
    NumKeysWanted = Max - length(Keys),
    WorkerSeq = lists:seq(1, erlang:min(N, NumKeysWanted)),
    %% Note that we'll get a DOWN message if we monitor a dead pid, so we don't have to
    %% worry about what happens between the supervisor starting the worker and our call to
    %% attach the monitor.
    Workers = [ chef_keygen_worker_sup:new_worker(Self) || _I <- WorkerSeq ],
    NewInflight = [
                   begin
                       _MRef = erlang:monitor(process, Pid),
                       Pid
                   end
                   || {ok, Pid} <- Workers ],
    OKCount = length(NewInflight),
    State#state{avail_workers = N - OKCount,
                inflight = NewInflight ++ Inflight}.

export_key_pair(#key_pair{public_key = Pub, private_key = Priv}) ->
    {Pub, Priv}.

log_non_normal(_Pid, normal) ->
    ok;
log_non_normal(Pid, Reason) ->
    error_logger:error_report({chef_keygen_cache, worker_crash, Pid, Reason}).