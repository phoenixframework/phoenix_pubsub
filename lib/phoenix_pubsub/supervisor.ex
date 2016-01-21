defmodule Phoenix.PubSub.Supervisor do
  use Application
  import Supervisor.Spec, warn: false

  def start(_type, :test) do
    start([
      supervisor(Phoenix.PubSub.PG2, [Phoenix.PubSub.Test.PubSub, [pool_size: 1]]),
    ])
  end
  def start(_type, :dev) do
    start([
      worker(Task, [fn -> node_connect() end])
    ])
  end
  def start(_type, _env), do: start([])
  def start(children) do
    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end

  defp node_connect() do
    for n <- 1..5, n != node(), do: Node.connect(:"n#{n}@127.0.0.1")
    :timer.sleep(5000)
    node_connect()
  end
end
