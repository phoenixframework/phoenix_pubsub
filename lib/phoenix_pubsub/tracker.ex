defmodule Phoenix.Tracker do
  use GenServer
  alias Phoenix.Tracker.{Clock, State}
  require Logger

  # TODO proper moduledoc
  @moduledoc """
  What you plug in your app's supervision tree...

  ## Required options:

    * `:name` - The name of the server, such as: `MyApp.UserState`
    * `:pubsub_server` - The name of the PubSub server, such as: `MyApp.PubSub`

  ## Optional configuration:

    * `heartbeat_interval` - The interval in milliseconds to send heartbeats
      across the cluster. Default `3000`
    * `nodedown_interval` - The interval in milliseconds to flag a node
      as down temporarily down.
      Default `heartbeat_interval * 3` (three missed gossip windows)
    * `permdown_interval` - The interval in milliseconds to flag a node
      as permanently down, and discard its state.
      Default `1_200_000` (20 minutes)
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
    server_name
    |> GenServer.call({:list, topic})
    |> State.get_by_topic(topic)
    |> Enum.group_by(fn {_conn, key, _meta} -> key end)
    |> Enum.into(%{}, fn {key, metas} ->
      meta = for {_conn, _key, meta} <- metas do
        {%{ref: ref}, meta} = Map.pop(meta, :phx_presence)
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
    heartbeat_interval = opts[:heartbeat_interval] || 3_000
    nodedown_interval  = opts[:nodedown_interval] || (heartbeat_interval * 3)
    permdown_interval  = opts[:permdown_interval] || 1_200_000
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
            nodes: %{},
            pending_clockset: [],
            presences: State.new({node_name, vsn}),
            heartbeat_interval: heartbeat_interval,
            nodedown_interval: nodedown_interval,
            permdown_interval: permdown_interval}}
  end

  defp send_stuttered_heartbeat(pid, interval) do
    Process.send_after(pid, :heartbeat, Enum.random(0..trunc(interval * 0.5)))
  end

  def handle_info(:heartbeat, state) do
    broadcast_from(state, self(), {:pub, :gossip, state.node, clock(state)})
    {:noreply, state
               |> request_transfer_from_nodes_needing_synced()
               |> detect_nodedowns()
               |> schedule_next_heartbeat()}
  end

  def handle_info({:pub, :gossip, {_name, _vsn} = from_node, clocks}, state) do
    {:noreply, state
               |> put_pending_clock(clocks)
               |> handle_gossip(from_node)}
  end

  def handle_info({:pub, :transfer_req, ref, from_node, _clocks}, state) do
    Logger.debug "#{state.node_name}: transfer_req from #{inspect from_node}"
    msg = {:pub, :transfer_ack, ref, state.node, state.presences}
    direct_broadcast(state, from_node, msg)

    {:noreply, state}
  end

  def handle_info({:pub, :transfer_ack, _ref, from_node, remote_presences}, state) do
    Logger.debug "#{state.node_name}: transfer_ack from #{inspect from_node}"
    {presences, joined, left} = State.merge(state.presences, remote_presences)

    for {_node, {_conn, topic, key, meta}} <- joined do
      local_broadcast_join(state, topic, key, meta)
    end
    for {_node, {_conn, topic, key, meta}} <- left do
      local_broadcast_leave(state, topic, key, meta)
    end

    {:noreply, %{state | presences: presences}}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    {:noreply, drop_presence(state, pid)}
  end

  def handle_call({:track, pid, topic, key, meta}, _from, state) do
    {:reply, :ok, put_presence(state, pid, topic, key, meta)}
  end

  def handle_call({:list, _topic}, _from, state) do
    {:reply, state.presences, state}
  end

  defp put_presence(state, pid, topic, key, meta) do
    Process.link(pid)
    meta = Map.put(meta, :phx_presence, %{ref: random_ref()})
    local_broadcast_join(state, topic, key, meta)

    %{state | presences: State.join(state.presences, pid, topic, key, meta)}
  end

  defp drop_presence(state, conn) do
    for {topic, key, meta} <- State.get_by_conn(state.presences, conn) do
      local_broadcast_leave(state, topic, key, meta)
    end

    %{state | presences: State.part(state.presences, conn)}
  end

  defp handle_gossip(state, {name, vsn} = from_node) do
    case Map.fetch(state.nodes, name) do
      :error                 -> nodeup(state, from_node)
      {:ok, %{vsn: ^vsn}}    -> node_active(state, from_node)
      {:ok, %{vsn: old_vsn}} ->
        state |> permdown({name, old_vsn}) |> nodeup(from_node)
    end
  end

  defp request_transfer_from_nodes_needing_synced(state) do
    needs_synced = clockset_to_sync(state)
    Logger.debug "#{state.node_name}: heartbeat, needs_synced: #{inspect needs_synced}"
    for target_node <- needs_synced, do: request_transfer(state, target_node)

    %{state | pending_clockset: []}
  end

  defp request_transfer(state, {name, _vsn} = target_node) do
    Logger.debug "#{state.node_name}: request_transfer from #{name}"
    ref = make_ref()
    msg = {:pub, :transfer_req, ref, state.node, clock(state)}
    direct_broadcast(state, target_node, msg)
  end

  defp detect_nodedowns(state) do
    now = now_ms()
    Enum.reduce(state.nodes, state, fn {name, info}, acc ->
      downtime = now - info.last_gossip_at
      cond do
        downtime > state.permdown_interval -> permdown(acc, {name, info.vsn})
        downtime > state.nodedown_interval -> nodedown(acc, {name, info.vsn})
        true                               -> acc
      end
    end)
  end

  defp schedule_next_heartbeat(state) do
    Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    state
  end

  defp clock(state), do: State.clock(state.presences)

  defp clockset_to_sync(state) do
    state.pending_clockset
    |> Clock.append_clock(clock(state))
    |> Clock.clockset_nodes()
    |> Enum.reject(fn node -> node == state.node end)
  end

  defp put_pending_clock(state, clocks) do
    %{state | pending_clockset: Clock.append_clock(state.pending_clockset, clocks)}
  end

  defp node_active(state, {name, _vsn} = from_node) do
    if name in State.down_servers(state.presences) do
      nodeup(state, from_node)
    else
      %{state | nodes: put_in(state.nodes, [name, :last_gossip_at], now_ms())}
    end
  end

  defp nodeup(state, {name, vsn} = remote_node) do
    Logger.debug "#{state.node_name}: nodeup from #{inspect name}"
    {presences, joined, []} = State.node_up(state.presences, remote_node)

    for {_node, {_conn, topic, key, meta}} <- joined do
      local_broadcast_join(state, topic, key, meta)
    end

    %{state | presences: presences,
      nodes: Map.put(state.nodes, name, %{vsn: vsn, last_gossip_at: now_ms()})}
  end

  defp nodedown(state, {name, _vsn} = remote_node) do
    if not name in State.down_servers(state.presences) do
      Logger.debug "#{state.node_name}: nodedown from #{inspect name}"
      {presences, [], left} = State.node_down(state.presences, remote_node)
      for {_node, {_conn, topic, key, meta}} <- left do
        local_broadcast_leave(state, topic, key, meta)
      end

      %{state | presences: presences}
    else
      state
    end
  end

  defp permdown(state, {name, _vsn} = remote_node) do
    Logger.debug "#{state.node_name}: permanent nodedown detected #{inspect name}"
    state = nodedown(state, remote_node)
    presences = State.remove_down_nodes(state.presences, remote_node)

    {:noreply, %{state | presences: presences,
                         nodes: Map.delete(state.nodes, name)}}
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
    {%{ref: ref}, meta} = Map.pop(meta, :phx_presence)
    local_broadcast(state, topic, @join_event, %{key: key, meta: meta, ref: ref})
  end

  defp local_broadcast_leave(state, topic, key, meta) do
    {%{ref: ref}, meta} = Map.pop(meta, :phx_presence)
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
