defmodule Phoenix.Tracker.ShutdownHandler do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    tracker = Keyword.fetch!(opts, :tracker)
    Process.flag(:trap_exit, true)
    {:ok, %{tracker: tracker}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Phoenix.Tracker.graceful_permdown(state.tracker)
    :ok
  end
end
