-module(env_helper).
-compile(export_all).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec up(filename:all()) -> reference().
up(YamlFile) ->
    %% Maybe configure the docker-machine
    %% The 'CLUSTER_WITH' and stuff will be passed via the .yml config file
    ok.

-spec destroy(reference()) -> ok | {error, Reason :: term()}.
destroy(EnvRef) ->
    ok.

-spec create_networks(#{atom() => list(atom()
                                       | {Container :: atom(), EtcHostsName :: atom()})},
                     list()) -> ok.
create_networks(Networks, Opts) ->
    CenList = maps:fold(
                fun(Net, Conts, Acc) ->
                        [#{cenID => Net, containerIDs => Conts} | Acc]
                end, [], Networks),
    CenListJson = jiffy:encode(#{cenList => CenList}),
    Cens = jiffy:encode(maps:keys(Networks)),
    CinsList = maps:from_list([
                               {list_to_atom(atom_to_list(N) ++ "_cin"), [N]}
                               || N <- maps:keys(Networks)
                              ]),
    CinsListJson = jiffy:encode(CinsList),
    Cins = jiffy:encode(maps:keys(CinsList)),
    Cmd1 = curl(binary_to_list(CenListJson), "/cen/import"),
    Cmd2 = curl(binary_to_list(Cens), "/cen/make"),
    [cmd(C) || C <- [Cmd1, Cmd2]],
    wait_for_interfaces(Networks),
    timer:sleep(500),
    Cmd3 = curl(binary_to_list(CinsListJson), "/cin/import"),
    Cmd4 = curl(binary_to_list(Cins), "/cin/make"),
    [cmd(C) || C <- [Cmd3, Cmd4]],
    
    lists:foreach(
      fun(Net) ->
              update_etc_hosts(Net, maps:get(Net, Networks))
      end, maps:get(update_etc_hosts, Opts, [])).

-spec destroy_network(atom() | list(atom())) -> ok.
destroy_network(NetNames) ->
    NetNames1 = binary_to_list(jiffy:encode(NetNames)),
    cmd(curl(NetNames1, "/cen/destroy")).


-spec cont_ip(atom(), atom()) -> inet:ip4_address().
cont_ip(NetName, Cont) ->
    RawAddr = cont_ip_raw(NetName, Cont),
    case inet_parse:ipv4_address(RawAddr) of
        {ok, Addr} ->
            Addr;
        {error, einval} ->
            {error, {container_not_in_network, NetName}}
    end.

-spec run_cmd(atom() | list(atom()), string()) -> ok.
run_cmd(Conts, Cmd) when is_list(Conts) ->
    [run_cmd(C, Cmd) || C <- Conts];
run_cmd(Cont, Cmd) ->
    cmd(docker_exec(Cont, Cmd)).

-spec update_etc_hosts(atom(), list(atom())) -> ok.
update_etc_hosts(Net, Containers) ->
    ContToIp = lists:foldl(
                 fun(C, Acc) ->
                         maps:put(C,
                                  with_retries(
                                    fun() -> cont_ip_raw(Net, C) end,
                                    fun(IpRes) -> IpRes =:= "" end,
                                    5),
                                  Acc)
                 end, #{}, Containers),
    lists:foreach(
      fun({Cont, Ip}) ->
              [begin
                   Cmd = docker_exec(C, add_entry_to_etc_hosts(Ip, Cont)),
                   cmd(Cmd)
               end || {C, _} <- maps:to_list(maps:without([Cont], ContToIp))]
      end, maps:to_list(ContToIp)).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

cmd(Cmd0) ->
    Cmd1 = lists:flatten(Cmd0),
    io:format("Running: ~p~n",[Cmd1]),
    string:strip(os:cmd(Cmd1), both, $\n).

with_retries(WhatFn, RetryFn, NumberOfRetries) ->
    Res = WhatFn(),
    case RetryFn(Res) of
        true ->
            timer:sleep(200),
            with_retries(WhatFn, RetryFn, NumberOfRetries - 1);
        false ->
            Res
    end.

cont_ip_raw(Net, Cont) ->
    Cmd = docker_exec(Cont, ip_addr_show_grep_ip(Net)),
    cmd(Cmd).

interface_exists(Cont, Intf) ->
    Cmd = docker_exec(Cont, ip_addr_show_interface_exists(Intf)),
    case cmd(Cmd) of
        "no_interface" ->
            false;
        _ ->
            true
    end.

interface_ip_exists(Cont, Intf) ->
    Cmd = docker_exec(Cont, ip_addr_show_interface_exists(Intf)),
    case cmd(Cmd) of
        "no_interface" ->
            false;
        _ ->
            true
    end.


wait_for_interfaces(Networks) ->
    maps:fold(
      fun(Net, Conts, _) ->
              wait_for_net_interfaces(Net, Conts, 10)
      end, undefined, Networks).

wait_for_net_interfaces(_, [], _) ->
    ok;
wait_for_net_interfaces(_, _, 0) ->
    throw(cont_interfaces_down);
wait_for_net_interfaces(Net, [C | Cs] = Conts, Retries) ->
    case interface_exists(C, Net) of
        true ->
            wait_for_net_interfaces(Net, Cs, Retries);
        false ->
            timer:sleep(100),
            wait_for_net_interfaces(Net, Conts, Retries-1)
    end.

%%--------------------------------------------------------------------
%% Cmds
%%--------------------------------------------------------------------

docker_exec(Cont, Cmd) ->
    "docker exec " ++ atom_to_list(Cont) ++ " " ++ Cmd.

ip_addr_show_grep_ip(Intf) ->
    "ip addr show " ++ atom_to_list(Intf)  ++ "| grep 'inet ' | awk '{print $2}' | cut -d/ -f1".


add_entry_to_etc_hosts(Ip, Name) ->
    lists:flatten(io_lib:format("bash -c \"echo  '~s ~p' >> /etc/hosts\"", [Ip, Name])).

curl(Json, Path) ->
    lists:flatten(
      io_lib:format("curl -d '~s' ~s~s", [Json,
                                          application:get_env(env_helper,
                                                              lev_ip,
                                                              "192.168.99.100:8080"),
                                          Path])).

ip_addr_show_interface_exists(Intf) ->
    "ip addr show " ++ atom_to_list(Intf) ++ " 2> /dev/null || echo \"no_interface\"".

ip_addr_show_interface_ip_exists(Intf) ->
    "ip addr show " ++ atom_to_list(Intf) ++ " 2> /dev/null || echo \"no_interface\"".






















