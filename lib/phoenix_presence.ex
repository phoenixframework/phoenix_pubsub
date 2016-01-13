defmodule Phoenix.Presence do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      # TODO make it pull adapter from mix config
      supervisor(Phoenix.PubSub.PG2, [Phoenix.Presence.PubSub, [pool_size: 1]]),
      worker(Phoenix.Presence.Adapters.Global, [[]]),
      worker(Task, [fn -> node_connect() end]),
      supervisor(Phoenix.Presence.Tracker, [[pubsub_server: Phoenix.Presence.PubSub]]),
    ]

    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end

  defp node_connect() do
    for n <- 1..5, n != node() do
      Node.connect(:"n#{n}@127.0.0.1")
    end
    :timer.sleep(5000)
    node_connect()
  end
end
