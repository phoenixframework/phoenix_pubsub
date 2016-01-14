defmodule Phoenix.Presence.Server do
  use GenServer
  alias Phoenix.Presence.{NodeChecker, Registery, VectorClock}
  require Logger

  @moduledoc """
  The Presence Server...
  """

  @join_event "presence_join"
  @leave_event "presence_leave"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, [opts])
  end

  def track(%Phoenix.Socket{} = socket, user_id, meta) do
    track(socket.pubsub_server, socket.channel_pid, socket.topic, user_id, meta)
  end
  def track(pubsub_server, pid, topic, user_id, meta) do
    {:ok, server} = Registry.find_or_spawn(pubsub_server, topic)
    IO.puts "calling server"
    GenServer.call(server, {:track, pid, user_id, meta})
  end

  def list(%Phoenix.Socket{} = socket) do
    list(socket.pubsub_server, socket.topic)
  end
  def list(pubsub_server, topic) do
    if server = Registry.find(pubsub_server, topic) do
      GenServer.call(server, :list)
    else
      []
    end
  end

  @doc """
  opts - all from parent + :transfer_timeout...
  """
  # timeout for heatbeat
  # collect hearetbeats for interval
  # fetch best heartbeat
  # replace delta_interval
  def init([opts]) do
    pubsub_server    = Keyword.fetch!(opts, :pubsub_server)
    channel          = Keyword.fetch!(opts, :channel)
    namespaced_topic = namespaced_topic(channel)
    transfer_timeout = opts[:transfer_timeout] || 5_000
    gossip_timeout   = opts[:gossip_timeout] || 5_000
    delta_interval   = opts[:delta_interval] || 3_000
    node_name        = node() # todo must be adapter agnostic

    Phoenix.PubSub.subscribe(pubsub_server, self, namespaced_topic, link: true)
    :ok = NodeChecker.monitor_nodes(self)

    send(self, :catchup)

    # TODO must store node with each presence
    {:ok, %{requeset_timer: nil,
            namespaced_topic: namespaced_topic,
            channel: channel,
            pubsub_server: pubsub_server,
            transfer_ref: nil,
            transfer_timer: nil,
            gossip_ref: nil,
            gossip_timer: nil,
            delta_timer: schedule_delta_broadcast(delta_interval),
            delta_interval: delta_interval,
            node: node_name,
            presences: Presence.new(node_name),
            presence_meta: %{},
            refs_to_ids: %{},
            deltas: %{},
            count: 0,
            transfer_timeout: transfer_timeout,
            gossip_timeout: gossip_timeout,
            pending_deltas: false}}
  end

  def handle_info(:catchup, state) do
    {:noreply, catchup(state)}
  end

  # sync
  #
  # heartbeat - map node1 => clock
  #                 node2 => clock
  #
  # filter heartbeat clocks, queue clocks by asking for merge
  # find highest clock  => request merge from first dominant clock
  #
  #
  #

  def handle_info({:nodeup, name}, %{presence_meta: meta} = state) do
    {:noreply, state}
    # # node needs to broadcast when it comes up
    # Logger.debug "#{state.node}: nodeup detected #{name}"

    # {presences, joined, []} = Presence.node_up(state.presences, name)
    # merged_meta = Enum.reduce(joined, meta, fn {_from_node, id}, acc ->
    #   user_meta = meta[id]
    #   local_broadcast_join(state, id, user_meta)
    #   Map.put(acc, id, user_meta)
    # end)

    # {:noreply, %{state | presences: presences, presence_meta: merged_meta}}
  end

  # todo crdt
  def handle_info({:nodedown, name}, %{presence_meta: meta} = state) do
    Logger.debug "#{state.node}: nodedown detected #{name}"
    {presences, [], left} = Presence.node_down(state.presences, name)
    pruned_meta = Enum.reduce(left, meta, fn {_from_node, id}, acc ->
      local_broadcast_leave(state, id, meta[id])
      Map.delete(acc, id)
    end)

    {:noreply, %{state | presences: presences, presence_meta: pruned_meta}}
  end

  @doc """
  Another node has sent us their delta...
  """
  def handle_info({:deltas, {from_node, remote_presences, meta}}, state) do
    # mark down up
    Logger.debug "#{state.node}: got :deltas from #{from_node}"

    {:noreply, merge(state, from_node, remote_presences, meta)}
  end

  def handle_info(:broadcast_delta, %{pending_deltas: true} = state) do
    IO.puts "Broadcasting delta"
    message = {:deltas, {state.node, state.presences, state.presence_meta}}
    Phoenix.PubSub.broadcast_from!(state.pubsub_server, self(), state.namespaced_topic, message)
    timer = schedule_delta_broadcast(state.delta_interval)
    {:noreply, %{state | pending_deltas: false, delta_timer: timer}}
  end
  def handle_info(:broadcast_delta, state) do
    {:noreply, %{state | delta_timer: schedule_delta_broadcast(state.delta_interval)}}
  end

  def handle_info({:gossip_timeout, ref}, %{gossip_ref: ref} = state) do
    {:noreply, catchup(state)}
  end
  def handle_info({:gossip_timeout, _ref}, state) do
    {:noreply, state}
  end

  def handle_info({:transfer_timeout, ref}, %{transfer_ref: ref} = state) do
    {:noreply, catchup(state)}
  end
  def handle_info({:transfer_timeout, _ref}, state) do
    {:noreply, state}
  end

    @doc """
  Handle receiving fullfillment of gossip request from first responding node...
  """
  def handle_info({:gossip, ref, {:ok, dest_node, _topic}},
                  %{gossip_ref: ref} = state) do

    Logger.debug "#{state.node} received gossip fullfillment from #{dest_node}"
    Process.cancel_timer(state.gossip_timer)

    ref = request_transfer(state, dest_node)
    timer = Process.send_after(self, {:transfer_timeout, ref}, state.transfer_timeout)

    {:noreply, %{state | gossip_timer: nil,
                         gossip_ref: nil,
                         transfer_timer: timer,
                         transfer_ref: ref}}
  end
  def handle_info({:gossip, _ref, _}, state) do
    {:noreply, state}
  end

  @doc """
  Handle receiving fullfillment of transfer request from another node
  """
  # TODO crdt
  def handle_info({:transfer, ref, {:ok, from_node, _topic, remote_presences, meta}},
                  %{transfer_ref: ref} = state) do

    Logger.debug "#{state.node} received transfer fullfillment from #{from_node}"
    Process.cancel_timer(state.transfer_timer)
    state = merge(state, from_node, remote_presences, meta)

    {:noreply, %{state | transfer_timer: nil, transfer_ref: nil}}
  end
  def handle_info({:transfer, _ref, _}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, _type, _pid, _info}, state) do
    state = remove_presence(state, ref)
    if empty?(state) do
      {:stop, {:shutdown, :empty}, state}
    else
      {:noreply, state}
    end
  end

  @doc """
  Handles remote node requesting gossip of our state
  """
  def handle_info({:request_gossip, ref, requesting_node, _topic}, state) do
    Logger.debug "#{state.node} received gossip request from #{requesting_node}"

    message = {:gossip, ref, {:ok, state.node, state.topic}}
    Phoenix.PubSub.broadcast!({state.pubsub_server, requesting_node}, state.namespaced_topic, message)

    {:noreply, state}
  end


  @doc """
  Handles remote node requesting transfer of our state
  """
  # TODO crdt
  def handle_info({:request_transfer, ref, requesting_node, _topic}, state) do
    Logger.debug "#{state.node} received transfer request from #{requesting_node}"

    message = {:transfer, ref, {:ok, state.node, state.topic, state.presences, state.presence_meta}}
    Phoenix.PubSub.broadcast!({state.pubsub_server, requesting_node}, state.namespaced_topic, message)

    {:noreply, state}
  end

  def handle_call({:track, pid, id, meta}, _from, state) do
    {:reply, :ok, track_presence(state, pid, id, meta)}
  end

  def handle_call(:list, _from, %{presence_meta: meta} = state) do
    # todo avoid walking crdt twice
    users = for id <- Presence.online_users(state.presences), into: %{} do
      {id, meta[id]}
    end
    {:reply, users, state}
  end

  defp track_presence(state, pid, id, meta) do
    IO.puts "tracking #{id}"
    ref = Process.monitor(pid)
    local_broadcast_join(state, id, meta)

    add_presence(state, ref, id, meta)
  end

  defp local_broadcast_join(state, id, meta) do
    local_broadcast(state, state.topic, @join_event, %{id: id, meta: meta})
  end

  defp local_broadcast_leave(state, id, meta) do
    local_broadcast(state, state.topic, @leave_event, %{id: id, meta: meta})
  end

  # TODO crdt
  defp add_presence(state, ref, id, meta) do
    # %{state | metas: HashDict.put(state.metas, ref, {state.node, id, meta}),
    #           count: state.count + 1}
    %{state | presences: Presence.join(state.presences, id),
              presence_meta: Map.put(state.presence_meta, id, meta),
              refs_to_ids: Map.put(state.refs_to_ids, ref, id),
              pending_deltas: true}
  end

  # TODO crdt
  defp remove_presence(state, ref) do
    case Map.fetch(state.refs_to_ids, ref) do
      {:ok, id} ->
        presences = Presence.part(state.presences, id)
        {meta, presence_meta} = Map.pop(state.presence_meta, id)
        local_broadcast_leave(state, id, meta)

        %{state | presences: presences,
                  presence_meta: presence_meta,
                  refs_to_ids: Map.delete(state.refs_to_ids, ref),
                  pending_deltas: true}

      :error ->  state
    end
  end

  defp catchup(state) do
    Logger.debug "#{state.node} gossip who has #{state.topic}?"
    case request_gossip(state) do
      :no_members -> state # TODO what do we do with a single Node cluster and later nodeup?
      ref ->
        timer = Process.send_after(self, {:gossip_timeout, ref}, state.gossip_timeout)

        %{state | gossip_timer: timer, gossip_ref: ref}
    end
  end

  defp request_gossip(state) do
    case NodeChecker.list() do
      [] -> :no_members
      _ ->
        ref = make_ref()
        message = {:request_gossip, ref, state.node, state.topic}
        Phoenix.PubSub.broadcast_from!(state.pubsub_server, self(), state.namespaced_topic, message)
        ref
    end
  end

  defp request_transfer(state, dest_node) do
    ref = make_ref()
    message = {:request_transfer, ref, state.node, state.topic}
    Phoenix.PubSub.broadcast!({state.pubsub_server, dest_node}, state.namespaced_topic, message)

    ref
  end

  # TODO check crdt size
  defp empty?(state), do: Enum.empty?(state.presence_meta)

  defp namespaced_topic(topic) do
    "phx_presence:" <> topic
  end

  defp local_broadcast(state, topic, event, payload) do
    msg = %Phoenix.Socket.Broadcast{topic: topic, event: event, payload: payload}
    Phoenix.PubSub.broadcast({state.pubsub_server, state.node}, topic, msg)
  end

  defp merge(state, _from_node, remote_presences, meta) do
    {merged_presences, joined, left} = Presence.merge(state.presences, remote_presences)
    meta_after_joins = Enum.reduce(joined, state.presence_meta, fn {_from_node, id}, acc ->
      user_meta = meta[id]
      local_broadcast_join(state, id, user_meta)
      Map.put(acc, id, user_meta)
    end)
    merged_meta = Enum.reduce(left, meta_after_joins, fn {_from_node, id}, acc ->
      local_broadcast_leave(state, id, meta[id])
      Map.delete(acc, id)
    end)

    %{state | presences: merged_presences, presence_meta: merged_meta}
  end

  defp schedule_delta_broadcast(delta_interval) do
    Process.send_after(self(), :broadcast_delta, delta_interval)
  end
end
