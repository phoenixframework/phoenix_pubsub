defmodule Phoenix.PubSub.Supervisor do
  use Application
  import Supervisor.Spec, warn: false

  def start(_type, :test) do
    children = [
      supervisor(Phoenix.PubSub.PG2, [Phoenix.PubSub.Test.PubSub, [pool_size: 1]]),
    ]
    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end
  def start(_type, :dev) do
    children = [
      worker(Task, [fn -> node_connect() end])
    ]
    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end
  def start(_type, _env) do
    Supervisor.start_link([], [strategy: :one_for_one])
  end

  defp node_connect() do
    for n <- 1..5, n != node(), do: Node.connect(:"n#{n}@127.0.0.1")
    :timer.sleep(5000)
    node_connect()
  end
end
