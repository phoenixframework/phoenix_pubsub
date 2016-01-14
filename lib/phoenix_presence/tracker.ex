defmodule Phoenix.Presence.Tracker do
  use GenServer
  alias Phoenix.Presence.{NodeChecker, VectorClock}
  require Logger

  # TODO
  # Tracker.trac(socket, %{user_id: id, status: status})
  # Tracker.list_by(socket, :user_id)
  # => %{123 => [%{user_id: 123, status: "away"}], [%{user_id: 123, status: "online"}]}

  @moduledoc """
  What you plug in your app's supervision tree...

  Required options:

    * `:pubsub_server` -

  """

  @join_event "presence_join"
  @leave_event "presence_leave"

  ## Client

  def track(%Phoenix.Socket{} = socket, user_id) do
    track(socket.channel, socket.channel_pid, socket.topic, user_id)
  end
  def track(channel, pid, topic, user_id) do
    GenServer.call(channel, {:track, pid, topic, user_id})
  end

  def list(%Phoenix.Socket{} = socket) do
    list(socket.channel, socket.topic)
  end
  def list(channel, topic) do
    GenServer.call(channel, {:list, topic})
  end


  ## Server

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :channel))
  end

  def init(opts) do
    pubsub_server      = Keyword.fetch!(opts, :pubsub_server)
    channel            = Keyword.fetch!(opts, :channel)
    heartbeat_interval = opts[:heartbeat_interval] || 3_000
    node_name          = opts[:node_name] || node()
    namespaced_topic   = namespaced_topic(channel)

    Phoenix.PubSub.subscribe(pubsub_server, self(), namespaced_topic, link: true)
    send(self, :heartbeat)
    :ok = NodeChecker.monitor_nodes(self)

    {:ok, %{pubsub_server: pubsub_server,
            node: node_name,
            namespaced_topic: namespaced_topic,
            channel: channel,
            clocks: %{node_name => 0},
            pending_clocks: %{},
            pending_transfers: %{},
            presences: Presence.new(node_name),
            refs_to_ids: %{},
            heartbeat_interval: heartbeat_interval}}
  end

  def handle_info(:heartbeat, state) do
    broadcast(state, {:pub, :gossip, state.node, state.clocks})
    {_merged_clocks, needs_synced} = VectorClock.collapse_clocks(
      state.node, state.clocks, state.pending_clocks
    )
    Logger.debug "#{state.node}: heartbeat, needs_synced: #{inspect Map.keys(needs_synced)}"
    state = Enum.reduce(needs_synced, state, fn {target_node, _}, acc ->
      request_transfer(acc, target_node)
    end)

    Process.send_after(self, :heartbeat, state.heartbeat_interval)
    {:noreply, %{state | pending_clocks: %{}}}
  end

  def handle_info({:pub, :gossip, from_node, clocks}, state) do
    {:noreply, %{state | pending_clocks: Map.put(state.pending_clocks, from_node, clocks)}}
  end

  def handle_info({:pub, :transfer_req, ref, from_node, _remote_clocks}, state) do
    Logger.debug "#{state.node}: transfer_req from #{from_node}"
    msg = {:pub, :transfer_ack, ref, state.node, state.clocks, state.presences}
    direct_broadcast(state, from_node, msg)

    {:noreply, state}
  end
  # TODO handle ref/receiving "old" transfers
  def handle_info({:pub, :transfer_ack, ref, from_node, remote_clocks, remote_presences}, state) do
    Logger.debug "#{state.node}: transfer_ac from #{from_node}"
    clocks = VectorClock.merge_clocks(state.node, state.clocks, remote_clocks)
    {presences, joined, left} = Presence.merge(state.presences, remote_presences)

    IO.inspect {:joined, joined}
    IO.inspect {:left, left}

    for {_node, {topic, id}} <- joined, do: local_broadcast_join(state, topic, id)
    for {_node, {topic, id}} <- left, do: local_broadcast_leave(state, topic, id)

    {:noreply, %{state |
                 presences: presences,
                 pending_transfers: Map.delete(state.pending_transfers, from_node),
                 clocks: clocks}}
  end

  def handle_info({:nodeup, name}, state) do
    Logger.debug "#{state.node}: nodeup from #{name}"
    {presences, joined, []} = Presence.node_up(state.presences, name)

    for {_node, {topic, id}} <- joined, do: local_broadcast_join(state, topic, id)

    {:noreply, %{state | presences: presences,
                         clocks: VectorClock.inc(state.node, state.clocks)}}
  end
  def handle_info({:nodedown, name}, state) do
    Logger.debug "#{state.node}: nodedown from #{name}"
    {presences, [], left} = Presence.node_down(state.presences, name)

    for {_node, {topic, id}} <- left, do: local_broadcast_leave(state, topic, id)

    {:noreply, %{state | presences: presences,
                         clocks: VectorClock.inc(state.node, state.clocks)}}
  end

  def handle_info({:DOWN, ref, _type, _pid, _info}, state) do
    {:noreply, remove_presence(state, ref)}
  end

  def handle_call({:track, pid, topic, id}, _from, state) do
    {:reply, :ok, track_presence(state, pid, topic, id)}
  end

  def handle_call({:list, topic}, _from, state) do
    # TODO crdt will efficiently handle topics
    users =
      state.presences
      |> Presence.online_users()
      |> Stream.filter(fn {user_topic, _} -> topic == user_topic end)
      |> Enum.map(fn {_, id} -> %{id: id} end)

    {:reply, users, state}
  end

  defp track_presence(state, pid, topic, id) do
    ref = Process.monitor(pid)
    add_presence(state, ref, topic, id)
  end

  defp add_presence(state, ref, topic, id) do
    local_broadcast_join(state, topic, id)
    %{state | presences: Presence.join(state.presences, {topic, id}),
              clocks: VectorClock.inc(state.node, state.clocks),
              refs_to_ids: Map.put(state.refs_to_ids, ref, {topic, id})}
  end

  defp remove_presence(state, ref) do
    case Map.fetch(state.refs_to_ids, ref) do
      {:ok, {topic, id}} ->
        local_broadcast_leave(state, topic, id)

        %{state | presences: Presence.part(state.presences, {topic, id}),
                  clocks: VectorClock.inc(state.node, state.clocks),
                  refs_to_ids: Map.delete(state.refs_to_ids, ref)}

      :error ->  state
    end
  end

  defp request_transfer(%{node: target_node} = state, target_node) do
    state
  end
  defp request_transfer(state, target_node) do
    Logger.debug "#{state.node}: request_transfer from #{target_node}"
    ref = make_ref()
    direct_broadcast(state, target_node, {:pub, :transfer_req, ref, state.node, state.clocks})

    %{state | pending_transfers: Map.put(state.pending_transfers, target_node, ref)}
  end

  defp namespaced_topic(channel) do
    "phx_presence:#{channel}"
  end

  defp broadcast(state, msg) do
    Phoenix.PubSub.broadcast!(state.pubsub_server, state.namespaced_topic, msg)
  end

  defp direct_broadcast(state, target_node, msg) do
    Phoenix.PubSub.broadcast!({state.pubsub_server, target_node}, state.namespaced_topic, msg)
  end

  defp local_broadcast(state, topic, event, payload) do
    msg = %Phoenix.Socket.Broadcast{topic: topic, event: event, payload: payload}
    Phoenix.PubSub.broadcast({state.pubsub_server, state.node}, topic, msg)
  end

  defp local_broadcast_join(state, topic, id) do
    local_broadcast(state, topic, @join_event, %{id: id})
  end

  defp local_broadcast_leave(state, topic, id) do
    local_broadcast(state, topic, @leave_event, %{id: id})
  end
end
