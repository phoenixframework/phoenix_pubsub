defmodule Phoenix.Presence.Spawner do
  use Supervisor

  @moduledoc """
  Dynamically spawns presence servers...
  """

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :spawner))
  end

  def init(opts) do
    children = [
      worker(Phoenix.Presence.Server, [opts], restart: :transient)
    ]

    supervise children, strategy: :simple_one_for_one
  end
end
