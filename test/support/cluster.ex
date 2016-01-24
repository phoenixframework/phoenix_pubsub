defmodule Phoenix.PubSub.Cluster do
  def spawn do
    # Turn node into a distributed node with the given long name
    :net_kernel.start([:"master@127.0.0.1"])

    # Allow slave nodes to fetch all code from this node
    :erl_boot_server.start([])
    allow_boot to_char_list("127.0.0.1")

    # Start configured nodes as slaves
    Application.get_env(:phoenix_pubsub, :nodes, [])
    |> Enum.each(&(spawn_node(&1)))
  end

  defp spawn_node(node_host) do
    {:ok, slave} = :slave.start(to_char_list("127.0.0.1"), node_name(node_host), inet_loader_args)
    add_code_paths(slave)
    transfer_configuration(slave)
    ensure_applications_started(slave)
    {:ok, slave}
  end

  defp rpc(slave, module, method, args) do
    :rpc.block_call(slave, module, method, args)
  end

  defp inet_loader_args do
    "-loader inet -hosts 127.0.0.1 -setcookie #{:erlang.get_cookie}" |> to_char_list
  end

  defp allow_boot(host) do
    {:ok, ipv4} = :inet.parse_ipv4_address(host)
    :erl_boot_server.add_slave(ipv4)
  end

  defp add_code_paths(slave) do
    :rpc.block_call(slave, :code, :add_paths, [:code.get_path])
  end

  defp transfer_configuration(slave) do
    Application.get_all_env(:phoenix_pubsub) |> Enum.each(fn({config_key, config_value}) ->
      rpc(slave, Application, :put_env, [:phoenix_pubsub, config_key, config_value])
    end)
  end

  defp ensure_applications_started(slave) do
    Enum.each Application.loaded_applications, fn({app_name, _, _}) ->
      rpc(slave, :application, :ensure_all_started, [app_name])
    end
  end

  defp node_name(node_host) do
    node_host
    |> to_string
    |> String.split("@")
    |> Enum.at(0)
    |> String.to_atom
  end
end
