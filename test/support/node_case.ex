defmodule Phoenix.PubSub.NodeCase do

  @timeout 500
  @heartbeat 25
  @permdown 1000
  @pubsub Phoenix.PubSub.Test.PubSub

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true
      import unquote(__MODULE__)
      @moduletag :clustered
    end
  end

  defmodule TestTracker do
    def init(opts) do
      # store along side module name
      server = Keyword.fetch!(opts, :pubsub_server)
      {:ok, {server, Phoenix.PubSub.node_name(server)}}
    end

    def handle_join(topic, presence, state) do
      msg = %{topic: topic, event: "presence_join", payload: presence}
      Phoenix.PubSub.broadcast(state, topic, msg)
      {:ok, state}
    end

    def handle_leave(topic, presence, state) do
      msg = %{topic: topic, event: "presence_leave", payload: presence}
      Phoenix.PubSub.broadcast(state, topic, msg)
      {:ok, state}
    end
  end

  def subscribe(pid, topic) do
    :ok = Phoenix.PubSub.subscribe(@pubsub, pid, topic)
  end

  def subscribe_to_tracker(pid, tracker) do
    :ok = Phoenix.PubSub.subscribe(@pubsub, pid, "phx_presence:#{tracker}")
  end

  def start_tracker(node_name, opts) do
    call_node(node_name, fn -> start_tracker(opts) end)
  end

  def start_tracker(opts) do
    opts = Keyword.merge([
      pubsub_server: @pubsub,
      heartbeat_interval: @heartbeat,
      permdown_interval: @permdown,
      tracker: TestTracker,
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
      Phoenix.PubSub.subscribe(server, self(), topic)
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
        payload: %{key: unquote(key), meta: unquote(meta)}
      }, unquote(timeout)
    end
  end

  defmacro assert_leave(topic, key, meta, timeout \\ 500) do
    quote do
      assert_receive %{
        event: "presence_leave",
        topic: unquote(topic),
        payload: %{key: unquote(key), meta: unquote(meta)}
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
