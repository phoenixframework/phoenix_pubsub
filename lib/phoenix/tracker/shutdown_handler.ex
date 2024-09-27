defmodule Phoenix.Tracker.ShutdownHandler do
  @moduledoc false
  use GenServer

  def start_link(tracker) do
    GenServer.start_link(__MODULE__, tracker, name: __MODULE__)
  end

  @impl GenServer
  def init(tracker) do
    Process.flag(:trap_exit, true)
    {:ok, tracker}
  end

  @impl GenServer
  def terminate(_reason, tracker) do
    Phoenix.Tracker.graceful_permdown(tracker)
    :ok
  end
end
