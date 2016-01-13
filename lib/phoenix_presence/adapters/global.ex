defmodule Phoenix.Presence.Adapters.Global do
  @moduledoc """
  The default strategy using :global_group to monitor node events
  """

  @behaviour Phoenix.Presence.Adapter
  use GenServer
  alias Phoenix.Presence.Registry

  @server __MODULE__

  ## Client API

  def node(), do: :erlang.node()

  def monitor_nodes(pid) do
    GenServer.call(@server, {:monitor_nodes, pid})
  end

  def demonitor_nodes(pid) do
    GenServer.call(@server, {:demonitor_nodes, pid})
  end

  def list() do
    GenServer.call(@server, :list)
  end

  ## Server API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  def init(opts) do
    node_source = opts[:node_source] || Node
    :global_group.monitor_nodes(true)

    {:ok, %{node_source: node_source, subscribers: %{}}}
  end

  def handle_info({:nodeup, node}, state) do
    for {pid, _ref} <- state.subscribers, do: send(pid, {:nodeup, node})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, remove_subscriber(state, pid)}
  end

  def handle_info({:nodedown, node}, state) do
    for {pid, _ref} <- state.subscribers, do: send(pid, {:nodedown, node})
    {:noreply, state}
  end

  def handle_call({:monitor_nodes, pid}, _from, state) do
    {:reply, :ok, add_subscriber(state, pid, Process.monitor(pid))}
  end

  def handle_call({:demonitor_nodes, pid}, _from, state) do
    Process.demonitor(Map.get(state.subscribers, pid))
    {:reply, :ok, remove_subscriber(state, pid)}
  end

  def handle_call(:subscribers, _from, state) do
    {:reply, state.subscribers, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, state.node_source.list(), state}
  end

  defp remove_subscriber(state, pid),
    do: %{state | subscribers: Map.delete(state.subscribers, pid)}

  defp add_subscriber(state, pid, ref),
    do: %{state | subscribers: Map.put(state.subscribers, pid, ref)}

end
