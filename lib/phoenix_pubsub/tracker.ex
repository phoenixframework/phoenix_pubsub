defmodule Phoenix.Tracker do
  use GenServer
  alias Phoenix.Tracker.{Clock, State, VNode}
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
    :random.seed(:os.timestamp())
    pubsub_server      = Keyword.fetch!(opts, :pubsub_server)
    server_name        = Keyword.fetch!(opts, :name)
    heartbeat_interval = opts[:heartbeat_interval] || 3_000
    nodedown_interval  = opts[:nodedown_interval] || (heartbeat_interval * 3)
    permdown_interval  = opts[:permdown_interval] || 1_200_000
    node_name          = opts[:node_name] || node()
    namespaced_topic   = namespaced_topic(server_name)
    vnode              = VNode.new(node_name)

    Phoenix.PubSub.subscribe(pubsub_server, self(), namespaced_topic, link: true)
    send_stuttered_heartbeat(self(), heartbeat_interval)

    {:ok, %{server_name: server_name,
            pubsub_server: pubsub_server,
            vnode: vnode,
            namespaced_topic: namespaced_topic,
            vnodes: %{},
            pending_clockset: [],
            presences: State.new(VNode.ref(vnode)),
            heartbeat_interval: heartbeat_interval,
            nodedown_interval: nodedown_interval,
            permdown_interval: permdown_interval}}
  end

  defp send_stuttered_heartbeat(pid, interval) do
    Process.send_after(pid, :heartbeat, Enum.random(0..trunc(interval * 0.5)))
  end

  def handle_info(:heartbeat, state) do
    broadcast_from(state, self(), {:pub, :gossip, state.vnode, clock(state)})
    {:noreply, state
               |> request_transfer_from_nodes_needing_synced()
               |> detect_nodedowns()
               |> schedule_next_heartbeat()}
  end

  def handle_info({:pub, :gossip, from_node, clocks}, state) do
    {:noreply, state
               |> put_pending_clock(clocks)
               |> handle_gossip(from_node)}
  end

  def handle_info({:pub, :transfer_req, ref, from_node, _clocks}, state) do
    Logger.debug "#{state.vnode.name}: transfer_req from #{inspect from_node.name}"
    msg = {:pub, :transfer_ack, ref, state.vnode, state.presences}
    direct_broadcast(state, from_node, msg)

    {:noreply, state}
  end

  def handle_info({:pub, :transfer_ack, _ref, from_node, remote_presences}, state) do
    Logger.debug "#{state.vnode.name}: transfer_ack from #{inspect from_node.name}"
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

  defp handle_gossip(state, %VNode{vsn: vsn} = from_node) do
    case VNode.put_gossip(state.vnodes, from_node) do
      {vnodes, nil, %VNode{status: :up} = upped} ->
        nodeup(%{state | vnodes: vnodes}, upped)

      {vnodes, %VNode{vsn: ^vsn, status: :up}, %VNode{vsn: ^vsn, status: :up}} ->
        %{state | vnodes: vnodes}

      {vnodes, %VNode{vsn: ^vsn, status: :down}, %VNode{vsn: ^vsn, status: :up} = upped} ->
        nodeup(%{state | vnodes: vnodes}, upped)

      {vnodes, %VNode{vsn: old, status: :up} = downed, %VNode{vsn: ^vsn, status: :up} = upped} when old != vsn ->
        %{state | vnodes: vnodes} |> nodedown(downed) |> permdown(downed) |> nodeup(upped)

      {vnodes, %VNode{vsn: old, status: :down} = downed, %VNode{vsn: ^vsn, status: :up} = upped} when old != vsn ->
        %{state | vnodes: vnodes} |> permdown(downed) |> nodeup(upped)
    end
  end

  defp request_transfer_from_nodes_needing_synced(state) do
    needs_synced = clockset_to_sync(state)
    Logger.debug "#{state.vnode.name}: heartbeat, needs_synced: #{inspect needs_synced}"
    for target_node <- needs_synced, do: request_transfer(state, target_node)

    %{state | pending_clockset: []}
  end

  defp request_transfer(state, target_node) do
    Logger.debug "#{state.vnode.name}: request_transfer from #{target_node.name}"
    ref = make_ref()
    msg = {:pub, :transfer_req, ref, state.vnode, clock(state)}
    direct_broadcast(state, target_node, msg)
  end

  defp detect_nodedowns(%{permdown_interval: perm_int, nodedown_interval: temp_int} = state) do
    Enum.reduce(state.vnodes, state, fn {_name, vnode}, acc ->
      case VNode.detect_down(acc.vnodes, vnode, temp_int, perm_int) do
        {vnodes, %VNode{status: :up}, %VNode{status: :permdown} = down_node} ->
          %{acc | vnodes: vnodes} |> nodedown(down_node) |> permdown(down_node)

        {vnodes, %VNode{status: :down}, %VNode{status: :permdown} = down_node} ->
          permdown(%{acc | vnodes: vnodes}, down_node)

        {vnodes, %VNode{status: :up}, %VNode{status: :down} = down_node} ->
          nodedown(%{acc | vnodes: vnodes}, down_node)

        {vnodes, %VNode{status: unchanged}, %VNode{status: unchanged}} ->
          %{acc | vnodes: vnodes}
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
    |> Stream.map(fn {name, _vsn} -> Map.get(state.vnodes, name) end)
    |> Enum.filter(&(&1))
  end

  defp put_pending_clock(state, clocks) do
    %{state | pending_clockset: Clock.append_clock(state.pending_clockset, clocks)}
  end

  defp nodeup(state, remote_node) do
    Logger.debug "#{state.vnode.name}: nodeup from #{inspect remote_node.name}"
    {presences, joined, []} = State.node_up(state.presences, VNode.ref(remote_node))

    for {_node, {_conn, topic, key, meta}} <- joined do
      local_broadcast_join(state, topic, key, meta)
    end

    %{state | presences: presences}
  end

  defp nodedown(state, remote_node) do
    Logger.debug "#{state.vnode.name}: nodedown from #{inspect remote_node.name}"
    {presences, [], left} = State.node_down(state.presences, VNode.ref(remote_node))
    for {_node, {_conn, topic, key, meta}} <- left do
      local_broadcast_leave(state, topic, key, meta)
    end

    %{state | presences: presences}
  end

  defp permdown(state, remote_node) do
    Logger.debug "#{state.vnode.name}: permanent nodedown detected #{remote_node.name}"
    presences = State.remove_down_nodes(state.presences, VNode.ref(remote_node))

    {:noreply, %{state | presences: presences}}
  end

  defp namespaced_topic(server_name) do
    "phx_presence:#{server_name}"
  end

  defp broadcast_from(state, from, msg) do
    Phoenix.PubSub.broadcast_from!(state.pubsub_server, from, state.namespaced_topic, msg)
  end

  defp direct_broadcast(state, target_node, msg) do
    Phoenix.PubSub.broadcast!({state.pubsub_server, target_node.name}, state.namespaced_topic, msg)
  end

  defp local_broadcast(state, topic, event, payload) do
    msg = %Phoenix.Socket.Broadcast{topic: topic, event: event, payload: payload}
    Phoenix.PubSub.broadcast({state.pubsub_server, state.vnode.name}, topic, msg)
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
end
