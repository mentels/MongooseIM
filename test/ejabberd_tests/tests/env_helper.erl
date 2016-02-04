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
    wait_for_interfaces(Networks),
    Cmd3 = curl(binary_to_list(CinsListJson), "/cin/import"),
    Cmd4 = curl(binary_to_list(Cins), "/cin/make"),
    [os:cmd(C) || C <- [Cmd1, Cmd2, Cmd3, Cmd4]],
    lists:foreach(
      fun(Net) ->
              update_etc_hosts(Net, maps:get(Net, Networks))
      end, maps:get(update_etc_hosts, Opts, [])).

-spec destroy_network(atom() | list(atom())) -> ok.
destroy_network(NetNames) ->
    NetNames1 = binary_to_list(jiffy:encode(NetNames)),
    os:cmd(curl(NetNames1, "/cen/destroy")).


-spec cont_ip(atom(), atom()) -> inet:ip4_address().
cont_ip(NetName, Cont) ->
    RawAddr = cont_ip_raw(NetName, Cont),
    {ok, Addr} = inet_parse:ipv4_address(RawAddr),
    Addr.

-spec run_cmd(atom() | list(atom()), string()) -> ok.
run_cmd(Cont, Cmd) ->
    docker_exec(Cont, Cmd).

-spec update_etc_hosts(atom(), list(atom())) -> ok.
update_etc_hosts(Net, Containers) ->
    ContToIp = lists:foldl(
                 fun(C, Acc) ->
                         maps:put(C, cont_ip_raw(Net, C), Acc)
                 end, #{}, Containers),
    lists:foreach(
      fun({Cont, Ip}) ->
              [docker_exec(C, add_entry_to_etc_hosts(Ip, Cont)) ||
                  {C, _} <- maps:to_list(maps:without(Cont, ContToIp))]
      end, maps:to_list(ContToIp)).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------


cont_ip_raw(Net, Cont) ->
    Cmd = docker_exec(Cont, ip_addr_show_grep_ip(Net)),
    os:cmd(Cmd).

interface_exists(Cont, Intf) ->
    Cmd = docker_exec(Cont, ip_addr_show_interface_exists(Intf)),
    case os:cmd(Cmd) of
        "no_interface\n" ->
            false;
        _ ->
            true
    end.

wait_for_interfaces(Networks) ->
    maps:fold(
      fun(Net, Conts, _) ->
              wait_for_net_interfaces(Net, Conts)
      end, undefined, Networks).

wait_for_net_interfaces(_, []) ->
    ok;
wait_for_net_interfaces(Net, [C | Cs] = Conts) ->
    case interface_exists(C, Net) of
        true ->
            wait_for_net_interfaces(Net, Cs),
            timer:sleep(100);
        false ->
            wait_for_net_interfaces(Net, Conts)
    end.

%%--------------------------------------------------------------------
%% Cmds
%%--------------------------------------------------------------------

docker_exec(Cont, Cmd) ->
    "docker exec " ++ atom_to_list(Cont) ++ " " ++ Cmd.

ip_addr_show_grep_ip(Intf) ->
    "ip addr show " ++ atom_to_list(Intf)  ++ "| grep \"inet\\b\" | awk '{print $2}' | cut -d/ -f1".


add_entry_to_etc_hosts(Ip, Name) ->
    "echo '" ++ Ip ++ " " ++ Name ++ "' >> /etc/hosts".

curl(Json, Path) ->
    io_lib:format("curl -d ~p ~p~p", [Json, Path,application:get_env(env_helper,
                                                                     lev_ip,
                                                                     "localhost")]).

ip_addr_show_interface_exists(Intf) ->
    "ip addr show " ++ atom_to_list(Intf) ++ " 2> /dev/null || echo \"no_interface\"".






















