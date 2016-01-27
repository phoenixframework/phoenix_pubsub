defmodule Phoenix.Tracker do
  use GenServer
  alias Phoenix.Tracker.{Clock, State, VNode}
  require Logger

  @type state :: %{key: key :: term, meta: meta :: Map.t, ref: ref :: Strint.t}

  @callback handle_join(pubsub_server :: atom, topic :: String.t, state) :: :ok
  @callback handle_leave(pubsub_server :: atom, topic :: String.t, state) :: :ok

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
    * `clock_sample_windows` - The numbers of heartbeat windows to sample
      remote clocks before collapsing and requesting transfer. Default `2`

  """

  @join_event "presence_join"
  @leave_event "presence_leave"

  ## Client

  def track(server_name, pid, topic, user_id, meta) do
    GenServer.call(server_name, {:track, pid, topic, user_id, meta})
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

  def start_link(tracker, tracker_opts, server_opts) do
    name = Keyword.fetch!(server_opts, :name)
    GenServer.start_link(__MODULE__, [tracker, tracker_opts, server_opts], name: name)
  end

  def init([tracker, tracker_opts, opts]) do
    Process.flag(:trap_exit, true)
    :random.seed(:os.timestamp())
    pubsub_server        = Keyword.fetch!(opts, :pubsub_server)
    server_name          = Keyword.fetch!(opts, :name)
    heartbeat_interval   = opts[:heartbeat_interval] || 3_000
    nodedown_interval    = opts[:nodedown_interval] || (heartbeat_interval * 5)
    permdown_interval    = opts[:permdown_interval] || 1_200_000
    clock_sample_windows = opts[:clock_sample_windows] || 2
    node_name            = Phoenix.PubSub.node_name(pubsub_server)
    namespaced_topic     = namespaced_topic(server_name)
    vnode                = VNode.new(node_name)

    case tracker.init(tracker_opts) do
      {:ok, tracker_state} ->
        Phoenix.PubSub.subscribe(pubsub_server, self(), namespaced_topic, link: true)
        send_stuttered_heartbeat(self(), heartbeat_interval)

        {:ok, %{server_name: server_name,
                pubsub_server: pubsub_server,
                tracker: tracker,
                tracker_state: tracker_state,
                vnode: vnode,
                namespaced_topic: namespaced_topic,
                vnodes: %{},
                pending_clockset: [],
                presences: State.new(VNode.ref(vnode)),
                heartbeat_interval: heartbeat_interval,
                nodedown_interval: nodedown_interval,
                permdown_interval: permdown_interval,
                clock_sample_windows: clock_sample_windows,
                current_sample_count: clock_sample_windows}}

       other -> other
    end
  end

  defp send_stuttered_heartbeat(pid, interval) do
    Process.send_after(pid, :heartbeat, Enum.random(0..trunc(interval * 0.25)))
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
    if from_node, do: Logger.debug "#{state.vnode.name}: transfer_ack from #{inspect from_node.name}"
    {presences, joined, left} = State.merge(state.presences, remote_presences)

    {:noreply, state
               |> local_broadcast_joins(joined)
               |> local_broadcast_leaves(left)
               |> Map.put(:presences, presences)}
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

  def handle_call(:vnodes, _from, state) do
    {:reply, state.vnodes, state}
  end

  defp put_presence(state, pid, topic, key, meta) do
    Process.link(pid)
    meta = Map.put(meta, :phx_presence, %{ref: random_ref()})

    state
    |> local_broadcast_join(topic, key, meta)
    |> Map.put(:presences, State.join(state.presences, pid, topic, key, meta))
  end

  defp drop_presence(state, conn) do
    new_state =
      state.presences
      |> State.get_by_conn(conn)
      |> Enum.reduce(state, fn {topic, key, meta}, acc ->
        local_broadcast_leave(acc, topic, key, meta)
      end)

    %{new_state | presences: State.part(new_state.presences, conn)}
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

  defp request_transfer_from_nodes_needing_synced(%{current_sample_count: 1} = state) do
    needs_synced = clockset_to_sync(state)
    Logger.debug "#{state.vnode.name}: heartbeat, needs_synced: #{inspect needs_synced}"
    for target_node <- needs_synced, do: request_transfer(state, target_node)

    %{state | pending_clockset: [], current_sample_count: state.clock_sample_windows}
  end
  defp request_transfer_from_nodes_needing_synced(state) do
    %{state | current_sample_count: state.current_sample_count - 1}
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

    state
    |> local_broadcast_joins(joined)
    |> Map.put(:presences, presences)
  end

  defp nodedown(state, remote_node) do
    Logger.debug "#{state.vnode.name}: nodedown from #{inspect remote_node.name}"
    {presences, [], left} = State.node_down(state.presences, VNode.ref(remote_node))

    state
    |> local_broadcast_leaves(left)
    |> Map.put(:presences, presences)
  end

  defp permdown(state, remote_node) do
    Logger.debug "#{state.vnode.name}: permanent nodedown detected #{remote_node.name}"
    presences = State.remove_down_nodes(state.presences, VNode.ref(remote_node))

    %{state | presences: presences}
  end

  defp namespaced_topic(server_name) do
    "phx_presence:#{server_name}"
  end

  defp broadcast_from(state, from, msg) do
    Phoenix.PubSub.broadcast_from!(state.pubsub_server, from, state.namespaced_topic, msg)
  end

  defp direct_broadcast(state, target_node, msg) do
    Phoenix.PubSub.direct_broadcast!(target_node.name, state.pubsub_server, state.namespaced_topic, msg)
  end

  defp local_broadcast_joins(state, joined) do
    Enum.reduce(joined, state, fn {_node, {_conn, topic, key, meta}}, acc ->
      local_broadcast_join(acc, topic, key, meta)
    end)
  end

  defp local_broadcast_leaves(state, left) do
    Enum.reduce(left, state, fn {_node, {_conn, topic, key, meta}}, acc ->
      local_broadcast_leave(acc, topic, key, meta)
    end)
  end

  defp local_broadcast_join(state, topic, key, meta) do
    {%{ref: ref}, meta} = Map.pop(meta, :phx_presence)
    state.tracker.handle_join(topic, %{key: key, meta: meta, ref: ref}, state.tracker_state)
    |> handle_tracker_result(state)
  end

  defp local_broadcast_leave(state, topic, key, meta) do
    {%{ref: ref}, meta} = Map.pop(meta, :phx_presence)

    state.tracker.handle_leave(topic, %{key: key, meta: meta, ref: ref}, state.tracker_state)
    |> handle_tracker_result(state)
  end
  defp handle_tracker_result({:ok, tracker_state}, state) do
    %{state | tracker_state: tracker_state}
  end
  defp handle_tracker_result(other, state) do
    raise ArgumentError, """
    expected #{state.tracker} to return {:ok, state}, but got:

        #{inspect other}
    """
  end

  defp random_ref() do
    :crypto.strong_rand_bytes(8) |> :erlang.term_to_binary() |> Base.encode64()
  end
end
