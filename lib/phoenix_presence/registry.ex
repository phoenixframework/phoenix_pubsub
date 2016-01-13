defmodule Phoenix.Presence.Registry do
  use GenServer
  require Logger

  @moduledoc """
  Holds the presence server registry...
  """

  ## Client API

  @doc """
  Finds the presence server ...
  """
  def find(pubsub_server, topic) do
    pid = dirty_find(pubsub_server, topic)
    if pid && Process.alive?(pid), do: pid
  end

  @doc false
  def dirty_find(pubsub_server, topic) do
    table_name = Module.concat(pubsub_server, Registry)
    Logger.debug "looking up #{table_name} #{topic} #{node()}"
    case IO.inspect(:ets.lookup(table_name, topic)) do
      [{^topic, server_pid}] -> server_pid
      [] -> nil
    end
  end


  @doc """
  Finds a presence server or spawns one if not already started
  """
  def find_or_spawn(pubsub_server, topic) do
    case find(pubsub_server, topic) do
      pid when is_pid(pid) -> {:ok, pid}
      nil ->
        # TODO use ets dispatch table to avoid Module.concat
        table_name = Module.concat(pubsub_server, Registry)
        GenServer.call(table_name, {:spawn, topic})
    end
  end


  ## Server API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:registry])
  end

  def init(opts) do
    {:ok, %{pids_to_topics: HashDict.new(),
            table_name: opts[:table_name],
            pubsub_server: opts[:pubsub_server],
            spawner: opts[:spawner]}}
  end

  def handle_call({:spawn, topic}, _from, state) do
    if pid = find(state.pubsub_server, topic) do
      {:reply, {:ok, pid}, state}
    else
      Logger.debug "Spawning Presence.Server for \"#{topic}\""
      {:ok, pid} = Supervisor.start_child(state.spawner, [topic])
      Process.monitor(pid)
      true = :ets.insert(state.table_name, {topic, pid})

      {:reply, {:ok, pid}, put_reverse_lookup(state, pid, topic)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    topic = get_reverse_lookup(state, pid)
    true = :ets.match_delete(state.table_name, {topic, :_})
    {:noreply, delete_reverse_lookup(state, pid)}
  end

  defp put_reverse_lookup(state, pid, topic) do
    put_in(state.pids_to_topics, HashDict.put(state.pids_to_topics, pid, topic))
  end

  defp get_reverse_lookup(state, pid) do
    HashDict.fetch!(state.pids_to_topics, pid)
  end

  defp delete_reverse_lookup(state, pid) do
    put_in(state.pids_to_topics, HashDict.delete(state.pids_to_topics, pid))
  end
end
