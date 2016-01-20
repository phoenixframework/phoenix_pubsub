defmodule Phoenix.PubSub.Supervisor do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Task, [fn -> node_connect() end])
    ]

    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end

  defp node_connect() do
    for n <- 1..5, n != node(), do: Node.connect(:"n#{n}@127.0.0.1")
    :timer.sleep(5000)
    node_connect()
  end
end
