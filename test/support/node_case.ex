defmodule Phoenix.PubSub.NodeCase do
  @timeout 1000
  @heartbeat 100
  @permdown 1500
  @pubsub Phoenix.PubSubTest

  defmacro __using__(opts \\ []) do
    quote do
      use ExUnit.Case, async: unquote(Keyword.get(opts, :async, true))
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

  def subscribe_to_server(server) do
    :ok = Phoenix.PubSub.subscribe(@pubsub, namespaced_topic(server))
  end

  defp namespaced_topic(server), do: "phx_presence:#{server}"

  def shard_name(server), do: :"#{server}_shard0"

  def start_shard(node_name, opts) do
    opts = Keyword.put_new(opts, :report_events_to, self())
    call_node(node_name, fn -> start_shard(opts) end)
  end

  def graceful_permdown(node_name, server) do
    call_node(node_name, fn -> Phoenix.Tracker.Shard.graceful_permdown(server) end)
  end

  def drop_gossips(server) do
    :ok = GenServer.call(server, :unsubscribe)
  end

  def resume_gossips(server) do
    :ok = GenServer.call(server, :resubscribe)
  end

  def start_shard(opts) do
    opts = Keyword.merge(default_tracker_opts(), Keyword.put_new(opts, :report_events_to, self()))
    Phoenix.Tracker.Shard.start_link(TestTracker, opts, opts)
  end

  def start_pool(opts) do
    opts = Keyword.merge(default_pool_opts(), opts)
    Phoenix.Tracker.start_link(TestTracker, opts, opts)
  end

  defp default_pool_opts do
    Keyword.merge([shard_number: 0], default_tracker_opts())
  end

  defp default_tracker_opts do
    [
      pubsub_server: @pubsub,
      broadcast_period: @heartbeat,
      max_silent_periods: 2,
      permdown_period: @permdown,
      shard_number: 0,
    ]
  end

  def track_presence(node_name, server, pid, topic, user_id, meta) do
    call_node(node_name, fn ->
      Phoenix.Tracker.Shard.track(server, pid, topic, user_id, meta)
    end)
  end

  def spy_on_server(node_name, pubsub_server \\ @pubsub,
    target_pid, tracker_server) do
    spy_on_pubsub(node_name, pubsub_server, target_pid,
      "phx_presence:#{tracker_server}")
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

  defmacro assert_join(topic, key, meta, timeout \\ @timeout) do
    quote do
      assert_receive %{
        event: "presence_join",
        topic: unquote(topic),
        payload: {unquote(key), unquote(meta)}
      }, unquote(timeout)
    end
  end

  defmacro assert_leave(topic, key, meta, timeout \\ @timeout) do
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
    {_, vals} = call_node(node, fn -> get_values(tracker) end)
    Enum.map(vals, fn [{{_, pid, node}, _, _}] -> {node, pid} end)
  end

  def get_values(tracker) do
    GenServer.call(tracker, :values)
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
