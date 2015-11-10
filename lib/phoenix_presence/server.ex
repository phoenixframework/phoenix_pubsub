defmodule Phoenix.Presence.Server do
  use GenServer
  alias Phoenix.Presence.Adapters.Global
  alias Phoenix.Presence.NodeChecker
  alias Phoenix.Presence.Registry
  require Logger

  @moduledoc """
  The Presence Server...
  """

  @join_event "presence_join"
  @leave_event "presence_leave"
  @catching_up :catching_up
  @normal :normal
  @awaiting_transfer :awaiting_transfer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def track(%Phoenix.Socket{} = socket, user_id, meta) do
    track(socket.pubsub_server, socket.channel_pid, socket.topic, user_id, meta)
  end
  def track(pubsub_server, pid, topic, user_id, meta) do
    {:ok, server} = Registry.find_or_spawn(pubsub_server, topic)
    GenServer.call(server, {:track, pid, user_id, meta})
  end

  @doc """
  opts - all from parent + :transfer_timeout...
  """
  def init(opts) do
    topic            = Keyord.fetch!(opts, :topic)
    namespaced_topic = namespaced_topic(topic)
    pubsub_server    = Keyword.fetch!(opts, :pubsub_server)
    local_pub_server = Keyword.fetch!(opts, :local_pubsub_server)
    transfer_timeout = opts[:transfer_timeout] || 5_000

    Phoenix.PubSub.subscribe(pubsub_server, self, namespaced_topic, link: true)
    :ok = NodeChecker.monitor_nodes(self)

    send(self, :catchup)

    # TODO must store node with each presence
    {:ok, %{requeset_timer: nil,
            namespaced_topic: namespaced_topic,
            topic: topic,
            pubsub_server: pubsub_server,
            local_pubsub_server: local_pub_server,
            transfer_ref: nil,
            transfer_timer: nil,
            node: node(), # todo must be adapter agnostic
            metas: HashDict.new,
            count: 0,
            transfer_timeout: transfer_timeout,
            status: @catching_up}}
  end

  def handle_info(:catchup, state) do
    {:noreply, catchup(state)}
  end

  # todo crdt
  def handle_info({:nodeup, name}, state) do
    # delay if an old node comes back
    {:noreply, state}
  end

  # todo crdt
  def handle_info({:nodedown, name}, state) do
    {:noreply, state}
  end

  def handle_info({:transfer_timeout, _ref}, %{status: @awaiting_transfer} = state) do
    {:noreply, catchup(state)}
  end
  def handle_info({:transfer_timeout, _ref}, state) do
    {:noreply, state}
  end

  @doc """
  Handle receiving fullfillment of transfer request from another node
  """
  # TODO crdt
  def handle_info({:transfer, ref, dest_node, topic, payload},
                  %{status: @awaiting_transfer} = state) do

    Logger.debug "#{state.node} received transfer fullfillment from #{dest_node}"
    :erlang.cancel_timer(state.transfer_timer)

    {:noreply, %{state | transfer_timer: nil,
                         transfer_ref: nil,
                         status: @normal}}
  end
  def handle_info({:transfer, _ref, _dest_node, _group_name, _payload}, state) do
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

  # TODO crdt. merge deltas and broadcast local joins/leaves
  def handle_info({:delta, _group, topic, joins, leaves}, state) do

    {:noreply, state}
  end

  @doc """
  Handles remote node requesting transfer of our state
  """
  # TODO crdt
  def handle_info({:request_transfer, ref, requesting_node, topic}, state) do
    Logger.debug "#{state.node} received transfer request from #{requesting_node}"
    data = :our_crdt # todo
    NodeChecker.transfer(state.pubsub_server, ref, state.node, requesting_node, topic, data)

    {:noreply, state}
  end

  def handle_call({:track, pid, id, metas}, _from, state) do
    {:reply, :ok, track_presence(state, pid, id, metas)}
  end

  defp track_presence(state, pid, id, meta) do
    ref = Process.monitor(pid)
    payload = %{id: id, meta: meta}
    local_broadcast(state, state.topic, @join_event, payload)
    # TODO queue deltas
    broadcast_delta(state, state.topic, [payload], [])

    add_presence(state, ref, id, meta)
  end

  # TODO crdt
  defp add_presence(state, ref, id, meta) do
    %{state | metas: HashDict.put(state.metas, ref, {state.node, id, meta}),
              count: state.count + 1}
  end

  # TODO crdt
  defp remove_presence(state, ref) do
    case HashDict.fetch(state.metas, ref) do
      {:ok, {_node, id, meta}} ->
        local_broadcast(state, state.topic, @leave_event, meta)
        # TODO queue deltas
        broadcast_delta(state, state.namespaced_topic, [], [meta])

        %{state | metas: HashDict.delete(state.metas, ref), count: state.count - 1}

      :error ->  state
    end
  end

  defp catchup(state) do
    case NodeChecker.request_transfer(state.pubsub_server, state.node) do
      :no_members -> state # TODO what do we do with a single Node cluster and later nodeup?
      ref ->
        timer = Process.send_after(self, {:transfer_timeout, ref}, state.transfer_timeout)

        %{state | transfer_timer: timer,
                  transfer_ref: ref,
                  status: @awaiting_transfer}
    end
  end

  # TODO check crdt size
  defp empty?(state), do: state.counter == 0

  defp namespaced_topic(topic) do
    "phx_pres:" <> topic
  end

  defp local_broadcast(state, topic, event, payload) do
    msg = %Phoenix.Socket.Broadcast{topic: topic, event: event, payload: payload}
    Phoenix.PubSub.Local.broadcast(state.local_pubsub_server, :none, topic, msg)
  end

  defp broadcast_delta(state, topic, joins, leaves) do
    Phoenix.PubSub.broadcast_from(state.pubsub_server, self, state.namespaced_topic,
                                  {:delta, state.group, topic, joins, leaves})
  end
end
