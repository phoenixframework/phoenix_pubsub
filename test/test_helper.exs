exclude = Keyword.get(ExUnit.configuration(), :exclude, [])

cond do
  :clustered in exclude ->
    ExUnit.start()
  true ->
    :net_kernel.start([:"master@127.0.0.1"])
    nodes = Application.get_env(:phoenix_pubsub, :nodes, [])

    if Enum.all?(nodes, &Phoenix.PubSub.NodeCase.connect_and_recompile(&1) == true) do
      ExUnit.start()
    else
      IO.write :stderr, """
      Unable to connect to test nodes. To run distributed tests,
      you must start separate nodes before running `mix test`:

      #{for n <- nodes, do: "MIX_ENV=test iex --name #{n} -S mix\n"}

      If you would like to skip distributed tests, please run `mix test --exclude clustered`
      """
      System.halt()
    end
end
