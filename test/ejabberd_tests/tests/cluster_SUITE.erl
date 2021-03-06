%%==============================================================================
%% Copyright 2015 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================


-module(cluster_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(TEST_FILE(Filename, Config),
        filename:join([?config(data_dir, Config), Filename])).
-define(ENV_DSC(Config), ?TEST_FILE("env.yaml", Config)).

-define(VMARGS, "/opt/mongooseim/rel/mongooseim/etc/vm.args").
-define(MIM_CTL, "/opt/mongooseim/rel/mongooseim/bin/mongooseimctl").

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [test1].


%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config0) ->
    %% Start appropriate containers but do not start mongoose yet
    [{env_ref, env_helper:up(?ENV_DSC(Config0))} | Config0].

end_per_suite(Config) ->
    env_helper:destroy(ct:get_config(env_ref, Config)).

init_per_testcase(_, Config) ->
    %% Containers name are known from env.yaml
    env_helper:create_networks(#{clustering => [mim1, mim2],
                                 clients => [mim1, mim2]},
                               #{update_etc_hosts => [clustering]}),

    %% configure the cluster and run
    [env_helper:run_cmd(N, change_mim_sname_cmd(N)) || N <- [mim1, mim2]],
    env_helper:run_cmd(mim1, mim_ctl_cmd(start)),
    env_helper:run_cmd(mim2, mim_ctl_cmd('add_to_cluster mongooseim@mim1')),
    env_helper:run_cmd(mim2, mim_ctl_cmd(start)),

    %% Port is known from the configuration passed to the container
    Endpoints = [{Cont, env_helper:cont_ip(clients, Cont), Port}
                 || {Cont, Port} <- [{mim1, 5222}, {mim2, 5223}]],
    [{clients_endpoints, Endpoints} |Config].

end_per_testcase(_, Config) ->
    env_helper:destroy_network([clustering, clients]),
    Config.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

test1(Config) ->
    [{ok, _} = gen_tcp:connect(I, P, [{active, false}])
     || {_, I, P} <- ?config(clients_endpoints, Config)],
    ok.
    
%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

change_mim_sname_cmd(Hostname) ->
    io_lib:format(
      "sed -i 's/sname mongooseim@localhost/sname mongooseim@~p/g' ~s ",
      [Hostname, ?VMARGS]).

mim_ctl_cmd(Cmd) ->
    io_lib:format("~s ~s", [?MIM_CTL, Cmd]).

    
















