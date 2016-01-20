defmodule Phoenix.Presence.Tracker do
  use GenServer
  alias Presence.Clock
  require Logger

  # TODO
  # Tracker.track(socket, %{user_id: id, status: status})
  # Tracker.list_by(socket, :user_id)
  # => %{123 => [%{user_id: 123, status: "away"}], [%{user_id: 123, status: "online"}]}

  # Make crdt behaiour (maybe easier to test)

  @moduledoc """
  What you plug in your app's supervision tree...

  Required options:

    * `:pubsub_server` -

  """

  @join_event "presence_join"
  @leave_event "presence_leave"

  ## Client

  def track_presence(%Phoenix.Socket{} = socket, user_id, meta) do
    track_presence(socket.channel, socket.channel_pid, socket.topic, user_id, meta)
  end
  def track_presence(server_name, pid, topic, user_id, meta) do
    GenServer.call(server_name, {:track, pid, topic, user_id, meta})
  end

  def list_presences(%Phoenix.Socket{} = socket) do
    list_presences(socket.channel, socket.topic)
  end
  # TODO decide if need to make ref random
  def list_presences(server_name, topic) do
    server_name
    |> GenServer.call({:list, topic})
    |> Presence.get_by_topic(topic)
    |> Enum.group_by(fn {_ref, key, meta} -> key end)
    |> Enum.into(%{}, fn {key, metas} ->
      meta = for {ref, _key, meta} <- metas, do: %{meta: meta, ref: encode_ref(ref)}
      {key, meta}
    end)
  end

  ## Server

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    pubsub_server      = Keyword.fetch!(opts, :pubsub_server)
    server_name        = Keyword.fetch!(opts, :name)
    heartbeat_interval = opts[:heartbeat_interval] || 3_000
    node_name          = opts[:node_name] || node()
    namespaced_topic   = namespaced_topic(server_name)
    vsn = {:os.timestamp(), System.unique_integer([:positive, :monotonic])}

    Phoenix.PubSub.subscribe(pubsub_server, self(), namespaced_topic, link: true)
    # TODO random sleep before first heartbeat 1/2 to 1/4 heartbeat window
    send(self, :heartbeat)
    :ok = :global_group.monitor_nodes(true)

    {:ok, %{server_name: server_name,
            pubsub_server: pubsub_server,
            node: {node_name, vsn},
            node_name: node_name,
            namespaced_topic: namespaced_topic,
            nodes: %{},
            pending_clockset: [],
            pending_transfers: %{},
            presences: Presence.new({node_name, vsn}),
            heartbeat_interval: heartbeat_interval}}
  end

  def handle_info(:heartbeat, state) do
    broadcast_from(state, self(), {:pub, :gossip, state.node, clock(state)})
    needs_synced = clockset_to_sync(state)
    Logger.debug "#{state.node_name}: heartbeat, needs_synced: #{inspect needs_synced}"
    state = Enum.reduce(needs_synced, state, fn target_node, acc ->
      request_transfer(acc, target_node)
    end)

    Process.send_after(self, :heartbeat, state.heartbeat_interval)
    {:noreply, %{state | pending_clockset: []}}
  end

  def handle_info({:pub, :gossip, {name, vsn} = from_node, clocks}, state) do
    state = put_pending_clock(state, clocks)
    case Map.get(state.nodes, name) do
      nil            -> {:noreply, nodeup(state, from_node, clocks)}
      {^vsn, _clock} -> {:noreply, state}
      {old_vsn, _clock} ->
        # handle node_down/cleanup of
        {:noreply, state
                   |> nodedown({name, old_vsn})
                   |> nodeup(from_node, clocks)}
    end
  end

  def handle_info({:pub, :transfer_req, ref, from_node, _remote_clocks}, state) do
    Logger.debug "#{state.node_name}: transfer_req from #{inspect from_node}"
    msg = {:pub, :transfer_ack, ref, state.node, state.presences}
    direct_broadcast(state, from_node, msg)

    {:noreply, state}
  end
  # TODO handle ref/receiving "old" transfers
  def handle_info({:pub, :transfer_ack, ref, from_node, remote_presences}, state) do
    Logger.debug "#{state.node_name}: transfer_ack from #{inspect from_node}"
    {presences, joined, left} = Presence.merge(state.presences, remote_presences)

    IO.inspect {:joined, joined}
    IO.inspect {:left, left}

    for {_node, {ref, topic, key, meta}} <- joined do
      local_broadcast_join(state, topic, key, meta, ref)
    end
    for {_node, {ref, topic, key, meta}} <- left do
      local_broadcast_leave(state, topic, key, meta, ref)
    end

    {:noreply, %{state |
                 presences: presences,
                 pending_transfers: Map.delete(state.pending_transfers, from_node)}}
  end

  def handle_info({:nodeup, _name}, state) do
    {:noreply, state}
  end

  def handle_info({:nodedown, name}, state) do
    # TODO rely on heartbeats for nodedown
    case Map.fetch(state.nodes, name) do
      {:ok, {vsn, _clock}} -> {:noreply, nodedown(state, {name, vsn})}
      :error               -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    {:noreply, remove_presence(state, pid)}
  end

  def handle_call({:track, pid, topic, key, meta}, _from, state) do
    {:reply, :ok, do_track_presence(state, pid, topic, key, meta)}
  end

  # CRDT TODO
  # all operations require topic
  #
  def handle_call({:list, _topic}, _from, state) do
    {:reply, state.presences, state}
  end

  defp do_track_presence(state, pid, topic, key, meta) do
    Process.link(pid)
    add_presence(state, pid, topic, key, meta)
  end

  # add random "ref", use cprypto
  defp add_presence(state, ref, topic, key, meta) do
    local_broadcast_join(state, topic, key, meta, ref)
    %{state | presences: Presence.join(state.presences, ref, topic, key, meta)}
  end

  defp remove_presence(state, ref) do
    for {topic, key, meta} <- Presence.get_by_conn(state.presences, ref) do
      local_broadcast_leave(state, topic, key, meta, ref)
    end

    %{state | presences: Presence.part(state.presences, ref)}
  end

  defp request_transfer(state, {name, vsn} = target_node) do
    Logger.debug "#{state.node_name}: request_transfer from #{name}"
    ref = make_ref()
    direct_broadcast(state, target_node, {:pub, :transfer_req, ref, state.node, clock(state)})

    %{state | pending_transfers: Map.put(state.pending_transfers, target_node, ref)}
  end

  defp clock(state), do: Presence.clock(state.presences)

  defp clockset_to_sync(state) do
    state.pending_clockset
    |> Clock.append_clock(clock(state))
    |> Clock.clockset_nodes()
    |> Enum.reject(fn node -> node == state.node end)
  end

  defp put_pending_clock(state, clocks) do
    %{state | pending_clockset: Presence.Clock.append_clock(state.pending_clockset, clocks)}
  end

  defp nodeup(state, {name, vsn} = remote_node, clocks) do
    Logger.debug "#{state.node_name}: nodeup from #{inspect name}"
    {presences, joined, []} = Presence.node_up(state.presences, remote_node)

    for {_node, {ref, topic, key, meta}} <- joined do
      local_broadcast_join(state, topic, key, meta, ref)
    end

    %{state | presences: presences,
              nodes: Map.put(state.nodes, name, {vsn, clocks})}
  end

  defp nodedown(state, {name, vsn} = remote_node) do
    Logger.debug "#{state.node_name}: nodedown from #{inspect name}"
    {presences, [], left} = Presence.node_down(state.presences, remote_node)

    for {_node, {ref, topic, key, meta}} <- left do
      local_broadcast_leave(state, topic, key, meta, ref)
    end

    %{state | presences: presences,
              nodes: Map.delete(state.nodes, name)}
  end

  defp namespaced_topic(server_name) do
    "phx_presence:#{server_name}"
  end

  defp broadcast_from(state, from, msg) do
    Phoenix.PubSub.broadcast_from!(state.pubsub_server, from, state.namespaced_topic, msg)
  end

  defp direct_broadcast(state, {name, _vsn} = _target_node, msg) do
    Phoenix.PubSub.broadcast!({state.pubsub_server, name}, state.namespaced_topic, msg)
  end

  defp local_broadcast(state, topic, event, payload) do
    msg = %Phoenix.Socket.Broadcast{topic: topic, event: event, payload: payload}
    Phoenix.PubSub.broadcast({state.pubsub_server, state.node_name}, topic, msg)
  end

  defp local_broadcast_join(state, topic, key, meta, ref) do
    ref = encode_ref(ref)
    local_broadcast(state, topic, @join_event, %{key: key, meta: meta, ref: ref})
  end

  defp local_broadcast_leave(state, topic, key, meta, ref) do
    ref = encode_ref(ref)
    local_broadcast(state, topic, @leave_event, %{key: key, meta: meta, ref: ref})
  end

  defp encode_ref(ref) do
    # use random
    ref |> :erlang.term_to_binary() |> Base.encode64()
  end
end
