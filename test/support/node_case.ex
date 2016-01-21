defmodule Phoenix.PubSub.NodeCase do

  @timeout 100

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
      Phoenix.Tracker.track_presence(tracker, pid, topic, user_id, meta)
    end)
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
