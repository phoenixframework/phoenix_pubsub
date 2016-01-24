exclude = Keyword.get(ExUnit.configuration(), :exclude, [])

cond do
  :clustered in exclude ->
    ExUnit.start()
  true ->
    Phoenix.PubSub.Cluster.spawn()
    ExUnit.start()
end
