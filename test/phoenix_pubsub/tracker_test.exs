defmodule Phoenix.TrackerTest do
  use ExUnit.Case, async: true
  alias Phoenix.Tracker
  import Phoenix.PubSub.NodeCase
  alias Phoenix.Socket.Broadcast

  @pubsub Phoenix.PubSub.Test.PubSub
  @tracker Tracker1

  def spawn_pid, do: spawn(fn -> :timer.sleep(:infinity) end)

  setup_all do
    nodes = Application.get_env(:phoenix_pubsub, :nodes)[:names]
    {:ok, pid} = Phoenix.Tracker.start_link(
      name: @tracker,
      pubsub_server: Phoenix.PubSub.Test.PubSub,
      heartbeat_interval: 50,
    )

    :ok
  end

  test "heartbeats", config do
    Phoenix.PubSub.subscribe(@pubsub, self(), "phx_presence:#{@tracker}")
    assert_receive {:pub, :gossip, {:"master@127.0.0.1", _vsn}, _clocks}
    flush()
    assert_receive {:pub, :gossip, {:"master@127.0.0.1", _vsn}, _clocks}
    flush()
    assert_receive {:pub, :gossip, {:"master@127.0.0.1", _vsn}, _clocks}
  end

  test "gossip from unseen node triggers nodeup", config do
  end

  test "replicates and locally broadcasts presence_join/leave", config do
    # local joins
    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), "topic")
    :ok = Tracker.track_presence(@tracker, self(), "topic", "me", %{name: "me"})
    assert_receive %Broadcast{event: "presence_join",
                              topic: "topic",
                              payload: %{key: "me", meta: %{name: "me"}}}

    local_presence = spawn_pid()
    :ok = Tracker.track_presence(@tracker, local_presence , "topic", "me2", %{name: "me2"})
    assert_receive %Broadcast{event: "presence_join",
                              topic: "topic",
                              payload: %{key: "me2", meta: %{name: "me2"}}}

    # remote joins
    remote_presence = spawn_pid()
    {_, {:ok, _pid}} = spawn_tracker_on_node(:"slave1@127.0.0.1",
      name: @tracker,
      pubsub_server: Phoenix.PubSub.Test.PubSub,
      heartbeat_interval: 50,
    )
    {_, :ok} = track_presence_on_node(
      :"slave1@127.0.0.1", @tracker, remote_presence, "topic", "slave1", %{name: "slave1"}
    )
    assert_receive %Broadcast{event: "presence_join",
                              topic: "topic",
                              payload: %{key: "slave1", meta: %{name: "slave1"}}}

    # local leaves
    Process.exit(local_presence, :kill)
    assert_receive %Broadcast{event: "presence_leave",
                              topic: "topic",
                              payload: %{key: "me2", meta: %{name: "me2"}}}
    # remote leaves
    Process.exit(remote_presence, :kill)
    assert_receive %Broadcast{event: "presence_leave",
                              topic: "topic",
                              payload: %{key: "slave1", meta: %{name: "slave1"}}}
  end


  defp flush() do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
