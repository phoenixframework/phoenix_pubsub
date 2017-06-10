defmodule Phoenix.PubSub.NodeCase do
  @timeout 500
  @heartbeat 100
  @permdown 1500
  @pubsub Phoenix.PubSub.Test.PubSub

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true
      import unquote(__MODULE__)
      @moduletag :clustered

      @timeout unquote(@timeout)
      @heartbeat unquote(@heartbeat)
      @permdown unquote(@permdown)
    end
  end

  defmodule TestTracker do
    @behaviour Phoenix.Tracker

    def start_link(_opts), do: {:error, :not_implemented}

    def init(opts) do
      # store along side module name
      server = Keyword.fetch!(opts, :pubsub_server)
      {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
    end

    def handle_diff(diff, state) do
      for {topic, {joins, leaves}}  <- diff do
        for {key, meta} <- joins do
          msg = %{topic: topic, event: "presence_join", payload: {key, meta}}
          Phoenix.PubSub.direct_broadcast!(state.node_name, state.pubsub_server, topic, msg)
        end
        for {key, meta} <- leaves do
          msg = %{topic: topic, event: "presence_leave", payload: {key, meta}}
          Phoenix.PubSub.direct_broadcast!(state.node_name, state.pubsub_server, topic, msg)
        end
      end
      {:ok, state}
    end
  end

  def subscribe(topic) do
    :ok = Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  def subscribe_to_tracker(tracker) do
    :ok = Phoenix.PubSub.subscribe(@pubsub, namespaced_topic(tracker))
  end

  defp namespaced_topic(tracker), do: "phx_presence:#{tracker}"

  def start_tracker(node_name, opts) do
    call_node(node_name, fn -> start_tracker(opts) end)
  end

  def graceful_permdown(node_name, tracker) do
    call_node(node_name, fn -> Phoenix.Tracker.graceful_permdown(tracker) end)
  end

  def drop_gossips(tracker) do
    :ok = GenServer.call(tracker, :unsubscribe)
  end

  def resume_gossips(tracker) do
    :ok = GenServer.call(tracker, :resubscribe)
  end

  def start_tracker(opts) do
    opts = Keyword.merge([
      pubsub_server: @pubsub,
      broadcast_period: @heartbeat,
      max_silent_periods: 2,
      permdown_period: @permdown,
    ], opts)
    Phoenix.Tracker.start_link(TestTracker, opts, opts)
  end

  def track_presence(node_name, tracker, pid, topic, user_id, meta) do
    call_node(node_name, fn ->
      Phoenix.Tracker.track(tracker, pid, topic, user_id, meta)
    end)
  end

  def start_pubsub(node_name, adapter, server_name, opts) do
    call_node(node_name, fn ->
      adapter.start_link(server_name, opts)
    end)
  end

  def spy_on_tracker(node_name, server \\ @pubsub, target_pid, tracker) do
    spy_on_pubsub(node_name, server, target_pid, "phx_presence:#{tracker}")
  end

  def spy_on_pubsub(node_name, server \\ @pubsub, target_pid, topic) do
    call_node(node_name, fn ->
      Phoenix.PubSub.subscribe(server, topic)
      loop = fn next ->
        receive do
          msg -> send target_pid, {node_name, msg}
        end
        next.(next)
      end
      loop.(loop)
    end)
  end

  defmacro assert_join(topic, key, meta, timeout \\ 500) do
    quote do
      assert_receive %{
        event: "presence_join",
        topic: unquote(topic),
        payload: {unquote(key), unquote(meta)}
      }, unquote(timeout)
    end
  end

  defmacro assert_leave(topic, key, meta, timeout \\ 500) do
    quote do
      assert_receive %{
        event: "presence_leave",
        topic: unquote(topic),
        payload: {unquote(key), unquote(meta)}
      }, unquote(timeout)
    end
  end

  defmacro assert_map(pattern, map, size) do
    quote bind_quoted: [map: map, size: size], unquote: true do
      assert unquote(pattern) = map
      assert map_size(map) == size
    end
  end

  def flush() do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  def get_values(node, tracker) do
    table = :sys.get_state(tracker).presences.values
    {_, vals} = call_node(node, fn -> get_values(table) end)
    Enum.map(vals, fn [{{_, pid, node}, _, _}] -> {node, pid} end)
  end

  def get_values(table) do
    :ets.match(table, :"$1")
  end

  defp call_node(node, func) do
    parent = self()
    ref = make_ref()

    pid = Node.spawn_link(node, fn ->
      result = func.()
      send parent, {ref, result}
      ref = Process.monitor(parent)
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      end
    end)

    receive do
      {^ref, result} -> {pid, result}
    after
      @timeout -> {pid, {:error, :timeout}}
    end
  end
end
