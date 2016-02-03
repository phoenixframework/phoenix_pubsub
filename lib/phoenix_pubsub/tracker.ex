defmodule Phoenix.Tracker do
  use GenServer
  alias Phoenix.Tracker.{Clock, State, VNode}
  require Logger

  @type presences :: %{ String.t => %{metas: [map]}}
  @type presence :: %{key: String.t, meta: map}
  @type topic :: String.t

  @callback start_link(Keyword.t) :: {:ok, pid} | {:error, reason :: term} :: :ignore
  @callback init(Keyword.t) :: {:ok, pid} | {:error, reason :: term}
  @callback handle_diff(%{topic => {joins :: presences, leaves :: presences}}, state :: term) :: {:ok, state :: term}

  # TODO proper moduledoc
  @moduledoc """
  What you plug in your app's supervision tree...

  ## Required options:

    * `:name` - The name of the server, such as: `MyApp.UserState`
    * `:pubsub_server` - The name of the PubSub server, such as: `MyApp.PubSub`

  ## Optional configuration:

    * `heartbeat_interval` - The interval in milliseconds to send heartbeats
      across the cluster. Default `1000`
    * `nodedown_interval` - The interval in milliseconds to flag a node
      as down temporarily down.
      Default `heartbeat_interval * 5` (five missed gossip windows)
    * `permdown_interval` - The interval in milliseconds to flag a node
      as permanently down, and discard its state.
      Default `1_200_000` (20 minutes)
    * `clock_sample_windows` - The numbers of heartbeat windows to sample
      remote clocks before collapsing and requesting transfer. Default `2`
    * log_level - The log level to log events, defaults `:debug` and can be
      disabled with `false`

  """

  @join_event "presence_join"
  @leave_event "presence_leave"

  ## Client

  @doc """
  TODO
  """
  def track(server_name, pid, topic, key, meta) when is_pid(pid) and is_map(meta) do
    GenServer.call(server_name, {:track, pid, topic, key, meta})
  end

  @doc """
  TODO
  """
  def untrack(server_name, pid, topic, key) when is_pid(pid) do
    GenServer.call(server_name, {:untrack, pid, topic, key})
  end
  def untrack(server_name, pid) when is_pid(pid) do
    GenServer.call(server_name, {:untrack, pid})
  end

  @doc """
  TODO
  """
  def update(server_name, pid, topic, key, meta) when is_pid(pid) and is_map(meta) do
    GenServer.call(server_name, {:update, pid, topic, key, meta})
  end

  @doc """
  TODO
  """
  def list(server_name, topic) do
    # TODO avoid extra map (ideally crdt does an ets select only returning {key, meta})
    server_name
    |> GenServer.call({:list, topic})
    |> State.get_by_topic(topic)
    |> Enum.map(fn {_conn, key, meta} -> {key, meta} end)
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
    heartbeat_interval   = opts[:heartbeat_interval] || 1000
    nodedown_interval    = opts[:nodedown_interval] || (heartbeat_interval * 5)
    permdown_interval    = opts[:permdown_interval] || 1_200_000
    clock_sample_windows = opts[:clock_sample_windows] || 2
    log_level            = Keyword.get(opts, :log_level, false)
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
                log_level: log_level,
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
    log state, fn -> "#{state.vnode.name}: transfer_req from #{inspect from_node.name}" end
    msg = {:pub, :transfer_ack, ref, state.vnode, state.presences}
    direct_broadcast(state, from_node, msg)

    {:noreply, state}
  end

  def handle_info({:pub, :transfer_ack, _ref, from_node, remote_presences}, state) do
    if from_node, do: log(state, fn -> "#{state.vnode.name}: transfer_ack from #{inspect from_node.name}" end)
    {presences, joined, left} = State.merge(state.presences, remote_presences)

    {:noreply, state
               |> report_diff(joined, left)
               |> Map.put(:presences, presences)}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    {:noreply, drop_presence(state, pid)}
  end

  def handle_call({:track, pid, topic, key, meta}, _from, state) do
    {:reply, :ok, put_presence(state, pid, topic, key, meta)}
  end

  def handle_call({:untrack, pid, topic, key}, _from, state) do
    new_state = drop_presence(state, pid, topic, key)
    if State.get_by_conn(new_state.presences, pid) == [] do
      Process.unlink(pid)
    end
    {:reply, :ok, new_state}
  end

  def handle_call({:untrack, pid}, _from, state) do
    Process.unlink(pid)
    {:reply, :ok, drop_presence(state, pid)}
  end

  def handle_call({:update, pid, topic, key, new_meta}, _from, state) do
    case State.get_by_conn(state.presences, pid, topic, key) do
      nil ->
        {:reply, {:error, :nopresence}, state}
      {{_node, _}, {_pid, _topic, ^key, prev_meta}} ->
        {:reply, :ok, put_update(state, pid, topic, key, new_meta, prev_meta)}
    end
  end

  def handle_call({:list, _topic}, _from, state) do
    {:reply, state.presences, state}
  end

  def handle_call(:vnodes, _from, state) do
    {:reply, state.vnodes, state}
  end

  defp put_update(state, pid, topic, key, meta, %{phx_ref: ref} = prev_meta) do
    state
    |> Map.put(:presences, State.part(state.presences, pid, topic, key))
    |> put_presence(pid, topic, key, Map.put(meta, :phx_ref_prev, ref), prev_meta)
  end
  defp put_presence(state, pid, topic, key, meta, prev_meta \\ nil) do
    Process.link(pid)
    meta = Map.put(meta, :phx_ref, random_ref())

    state
    |> report_diff_join(topic, key, meta, prev_meta)
    |> Map.put(:presences, State.join(state.presences, pid, topic, key, meta))
  end

  defp drop_presence(state, conn, topic, key) do
    if leave = State.get_by_conn(state.presences, conn, topic, key) do
      state
      |> report_diff([], [leave])
      |> Map.put(:presences, State.part(state.presences, conn, topic, key))
    else
      state
    end
  end
  defp drop_presence(state, conn) do
    leaves = State.get_by_conn(state.presences, conn)

    state
    |> report_diff([], leaves)
    |> Map.put(:presences, State.part(state.presences, conn))
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
    for target_node <- needs_synced, do: request_transfer(state, target_node)

    %{state | pending_clockset: [], current_sample_count: state.clock_sample_windows}
  end
  defp request_transfer_from_nodes_needing_synced(state) do
    %{state | current_sample_count: state.current_sample_count - 1}
  end

  defp request_transfer(state, target_node) do
    log state, fn -> "#{state.vnode.name}: request_transfer from #{target_node.name}" end
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
    log state, fn -> "#{state.vnode.name}: nodeup from #{inspect remote_node.name}" end
    {presences, joined, []} = State.node_up(state.presences, VNode.ref(remote_node))

    state
    |> report_diff(joined, [])
    |> Map.put(:presences, presences)
  end

  defp nodedown(state, remote_node) do
    log state, fn -> "#{state.vnode.name}: nodedown from #{inspect remote_node.name}" end
    {presences, [], left} = State.node_down(state.presences, VNode.ref(remote_node))

    state
    |> report_diff([], left)
    |> Map.put(:presences, presences)
  end

  defp permdown(state, remote_node) do
    log state, fn -> "#{state.vnode.name}: permanent nodedown detected #{remote_node.name}" end
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

  defp report_diff(state, joined, left) do
    join_diff = Enum.reduce(joined, %{}, fn {_node, {_conn, topic, key, meta}}, acc ->
      Map.update(acc, topic, {[{key, meta}], []}, fn {joins, leaves} ->
        {[{key, meta} | joins], leaves}
      end)
    end)
    full_diff = Enum.reduce(left, join_diff, fn {_node, {_conn, topic, key, meta}}, acc ->
      Map.update(acc, topic, {[], [{key, meta}]}, fn {joins, leaves} ->
        {joins, [{key, meta} | leaves]}
      end)
    end)

    full_diff
    |> state.tracker.handle_diff(state.tracker_state)
    |> handle_tracker_result(state)
  end

  defp report_diff_join(state, topic, key, meta, nil = _prev_meta) do
    %{topic => {[{key, meta}], []}}
    |> state.tracker.handle_diff(state.tracker_state)
    |> handle_tracker_result(state)
  end
  defp report_diff_join(state, topic, key, meta, prev_meta) do
    %{topic => {[{key, meta}], [{key, prev_meta}]}}
    |> state.tracker.handle_diff(state.tracker_state)
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

  defp log(%{log_level: false}, _msg_func), do: :ok
  defp log(%{log_level: level}, msg), do: Logger.log(level, msg)
end
