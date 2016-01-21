defmodule Phoenix.PubSub.NodeCase do

  @timeout 100

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false
      import unquote(__MODULE__)
    end
  end

  def connect_and_recompile(node) do
    if Node.connect(node) do
      case call_node(node, fn -> IEx.Helpers.recompile() end) do
        {_pid, {:restarted, [:phoenix_pubsub]}} -> true
        _ -> false
      end
    end
  end

  def spawn_tracker_on_node(node_name, opts) do
    call_node(node_name, fn ->
      Phoenix.Tracker.start_link(opts)
    end)
  end

  def track_presence_on_node(node_name, tracker, pid, topic, user_id, meta) do
    call_node(node_name, fn ->
      Phoenix.Tracker.track(tracker, pid, topic, user_id, meta)
    end)
  end

  defmacro assert_join(topic, key, meta, timeout \\ 500) do
    quote do
      assert_receive %Phoenix.Socket.Broadcast{
        event: "presence_join",
        topic: unquote(topic),
        payload: %{key: unquote(key), meta: unquote(meta)}
      }, unquote(timeout)
    end
  end

  defmacro assert_leave(topic, key, meta, timeout \\ 500) do
    quote do
      assert_receive %Phoenix.Socket.Broadcast{
        event: "presence_leave",
        topic: unquote(topic),
        payload: %{key: unquote(key), meta: unquote(meta)}
      }, unquote(timeout)
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
      :timer.sleep(:infinity)
    end)

    receive do
      {^ref, result} -> {pid, result}
    after
      @timeout -> {pid, {:error, :timeout}}
    end
  end
end
