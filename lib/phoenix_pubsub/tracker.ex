defmodule Phoenix.Tracker do
  use GenServer
  alias Presence.Clock
  require Logger

  # TODO proper moduledoc
  @moduledoc """
  What you plug in your app's supervision tree...

  ## Required options:

    * `:name` - The name of the server, such as: `MyApp.UserPresence`
    * `:pubsub_server` - The name of the PubSub server, such as: `MyApp.PubSub`

  ## Optional configuration:

    * `heartbeat_interval` - The interval in milliseconds to send heartbeats
      across the cluster. Default `3000`
    * `:adapter` - The state adapter for tracking presences. Defaults to
      the `Phoenix.Tracker.State` CRDT.
    * node_name - The name of the node. Default `node()`

  """

  @join_event "presence_join"
  @leave_event "presence_leave"

  ## Client

  # TODO decouple Socket
  def track(%Phoenix.Socket{} = socket, user_id, meta) do
    track(socket.channel, socket.channel_pid, socket.topic, user_id, meta)
  end
  def track(server_name, pid, topic, user_id, meta) do
    GenServer.call(server_name, {:track, pid, topic, user_id, meta})
  end

  def list(%Phoenix.Socket{} = socket) do
    list(socket.channel, socket.topic)
  end
  def list(server_name, topic) do
    {adapter, presences} = GenServer.call(server_name, {:list, topic})

    presences
    |> adapter.get_by_topic(topic)
    |> Enum.group_by(fn {_conn, key, _meta} -> key end)
    |> Enum.into(%{}, fn {key, metas} ->
      meta = for {_conn, _key, meta} <- metas do
        {ref, meta} = Map.pop(meta, :presence_ref)
        %{meta: meta, ref: ref}
      end
      {key, meta}
    end)
  end

  ## Server

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    timestamp = :os.timestamp()
    :random.seed(timestamp)
    pubsub_server      = Keyword.fetch!(opts, :pubsub_server)
    server_name        = Keyword.fetch!(opts, :name)
    adapter            = opts[:adapter] || Presence
    heartbeat_interval = opts[:heartbeat_interval] || 3_000
    nodedown_interval  = opts[:nodedown_interval] || (heartbeat_interval * 3)
    node_name          = opts[:node_name] || node()
    namespaced_topic   = namespaced_topic(server_name)
    vsn                = {timestamp, System.unique_integer()}

    Phoenix.PubSub.subscribe(pubsub_server, self(), namespaced_topic, link: true)
    send_stuttered_heartbeat(self(), heartbeat_interval)

    {:ok, %{server_name: server_name,
            pubsub_server: pubsub_server,
            node: {node_name, vsn},
            node_name: node_name,
            namespaced_topic: namespaced_topic,
            adapter: adapter,
            nodes: %{},
            pending_clockset: [],
            presences: adapter.new({node_name, vsn}),
            heartbeat_interval: heartbeat_interval,
            nodedown_interval: nodedown_interval}}
  end

  defp send_stuttered_heartbeat(pid, interval) do
    Process.send_after(pid, :heartbeat, Enum.random(0..trunc(interval * 0.5)))
  end

  def handle_info(:heartbeat, state) do
    broadcast_from(state, self(), {:pub, :gossip, state.node, clock(state)})
    needs_synced = clockset_to_sync(state)
    Logger.debug "#{state.node_name}: heartbeat, needs_synced: #{inspect needs_synced}"
    for target_node <- needs_synced, do: request_transfer(state, target_node)

    {state, _down_nodes} = detect_nodedowns(state)

    # TODO consider always stuttering heartbeats, instead just on init
    Process.send_after(self, :heartbeat, state.heartbeat_interval)
    {:noreply, %{state | pending_clockset: []}}
  end

  def handle_info({:pub, :gossip, {name, vsn} = from_node, clocks}, state) do
    state = put_pending_clock(state, clocks)
    case Map.get(state.nodes, name) do
      nil             -> {:noreply, nodeup(state, from_node)}
      %{vsn: ^vsn}    -> {:noreply, put_last_gossip(state, from_node)}
      %{vsn: old_vsn} ->
        {:noreply, state |> nodedown({name, old_vsn}) |> nodeup(from_node)}
    end
  end

  def handle_info({:pub, :transfer_req, ref, from_node, _remote_clocks}, state) do
    Logger.debug "#{state.node_name}: transfer_req from #{inspect from_node}"
    msg = {:pub, :transfer_ack, ref, state.node, state.presences}
    direct_broadcast(state, from_node, msg)

    {:noreply, state}
  end
  # TODO handle ref/receiving "old" transfers *or* CRDT should noop
  def handle_info({:pub, :transfer_ack, _ref, from_node, remote_presences}, state) do
    Logger.debug "#{state.node_name}: transfer_ack from #{inspect from_node}"
    {presences, joined, left} = state.adapter.merge(state.presences, remote_presences)

    for {_node, {_conn, topic, key, meta}} <- joined do
      local_broadcast_join(state, topic, key, meta)
    end
    for {_node, {_conn, topic, key, meta}} <- left do
      local_broadcast_leave(state, topic, key, meta)
    end

    {:noreply, %{state | presences: presences}}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    {:noreply, remove_presence(state, pid)}
  end

  def handle_call({:track, pid, topic, key, meta}, _from, state) do
    {:reply, :ok, do_track_presence(state, pid, topic, key, meta)}
  end

  def handle_call({:list, _topic}, _from, state) do
    {:reply, {state.adapter, state.presences}, state}
  end

  defp do_track_presence(state, pid, topic, key, meta) do
    Process.link(pid)
    add_presence(state, pid, topic, key, meta)
  end

  defp add_presence(state, conn, topic, key, meta) do
    meta = Map.put(meta, :presence_ref, random_ref())
    local_broadcast_join(state, topic, key, meta)
    %{state | presences: state.adapter.join(state.presences, conn, topic, key, meta)}
  end

  defp remove_presence(state, conn) do
    for {topic, key, meta} <- state.adapter.get_by_conn(state.presences, conn) do
      local_broadcast_leave(state, topic, key, meta)
    end

    %{state | presences: state.adapter.part(state.presences, conn)}
  end

  defp request_transfer(state, {name, _vsn} = target_node) do
    Logger.debug "#{state.node_name}: request_transfer from #{name}"
    ref = make_ref()
    direct_broadcast(state, target_node, {:pub, :transfer_req, ref, state.node, clock(state)})
  end

  defp detect_nodedowns(state) do
    now = now_ms()
    Enum.reduce(state.nodes, {state, []}, fn {name, info}, {acc, downs} ->
      if nodedown?(acc, name, now) do
        {nodedown(acc, {name, info.vsn}), [node | downs]}
      else
        {acc, downs}
      end
    end)
  end

  defp nodedown?(state, name, now) do
    now - get_in(state.nodes, [name, :last_gossip_at]) > state.nodedown_interval
  end

  defp clock(state), do: state.adapter.clock(state.presences)

  defp clockset_to_sync(state) do
    state.pending_clockset
    |> Clock.append_clock(clock(state))
    |> Clock.clockset_nodes()
    |> Enum.reject(fn node -> node == state.node end)
  end

  defp put_pending_clock(state, clocks) do
    %{state | pending_clockset: Clock.append_clock(state.pending_clockset, clocks)}
  end

  defp put_last_gossip(state, {name, _vsn}) do
    %{state | nodes: put_in(state.nodes, [name, :last_gossip_at], now_ms())}
  end

  defp nodeup(state, {name, vsn} = remote_node) do
    Logger.debug "#{state.node_name}: nodeup from #{inspect name}"
    {presences, joined, []} = state.adapter.node_up(state.presences, remote_node)

    for {_node, {_conn, topic, key, meta}} <- joined do
      local_broadcast_join(state, topic, key, meta)
    end

    %{state | presences: presences,
      nodes: Map.put(state.nodes, name, %{vsn: vsn, last_gossip_at: now_ms()})}
  end

  defp nodedown(state, {name, _vsn} = remote_node) do
    Logger.debug "#{state.node_name}: nodedown from #{inspect name}"
    {presences, [], left} = state.adapter.node_down(state.presences, remote_node)

    for {_node, {_conn, topic, key, meta}} <- left do
      local_broadcast_leave(state, topic, key, meta)
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

  defp local_broadcast_join(state, topic, key, meta) do
    {ref, meta} = Map.pop(meta, :presence_ref)
    local_broadcast(state, topic, @join_event, %{key: key, meta: meta, ref: ref})
  end

  defp local_broadcast_leave(state, topic, key, meta) do
    {ref, meta} = Map.pop(meta, :presence_ref)
    local_broadcast(state, topic, @leave_event, %{key: key, meta: meta, ref: ref})
  end

  defp random_ref() do
    :crypto.strong_rand_bytes(8) |> :erlang.term_to_binary() |> Base.encode64()
  end

  defp now_ms, do: :os.timestamp() |> time_to_ms()
  defp time_to_ms({mega, sec, micro}) do
    trunc(((mega * 1000000 + sec) * 1000) + (micro / 1000))
  end
end
