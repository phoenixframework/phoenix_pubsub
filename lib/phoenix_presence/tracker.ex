defmodule Phoenix.Presence.Tracker do
  use Supervisor

  @moduledoc """
  What you plug in your app's supervision tree...
  """

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def init(opts) do
    pubsub_server = Keyword.fetch!(opts, :pubsub_server)
    table_name = Module.concat(pubsub_server, Registry)
    child_opts = [pubsub_server: pubsub_server,
                  spawner: Module.concat(pubsub_server, Spawner),
                  registry: table_name,
                  table_name: table_name]

    ^table_name = :ets.new(table_name, [:set, :named_table, :public,
                           read_concurrency: true, write_concurrency: true])

    children = [
      supervisor(Phoenix.Presence.Spawner, [child_opts], restart: :permanent),
      worker(Phoenix.Presence.Registry, [child_opts], restart: :permanent)
    ]

    supervise children, strategy: :one_for_all
  end
end
