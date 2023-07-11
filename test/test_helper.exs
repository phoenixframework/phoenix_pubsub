Logger.configure(level: :info)
Application.put_env(:phoenix_pubsub, :test_adapter, {Phoenix.PubSub.PG2, []})
exclude = Keyword.get(ExUnit.configuration(), :exclude, [])

Supervisor.start_link(
  [{Phoenix.PubSub, name: Phoenix.PubSubTest, pool_size: 1}],
  strategy: :one_for_one
)

unless :clustered in exclude do
  Phoenix.PubSub.Cluster.spawn([
    :"node1@127.0.0.1",
    :"node2@127.0.0.1",
  ])
end

ExUnit.start()
