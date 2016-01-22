defmodule Phoenix.TrackerTest do
  use Phoenix.PubSub.NodeCase
  alias Phoenix.Tracker

  @pubsub Phoenix.PubSub.Test.PubSub

  def spawn_pid, do: spawn(fn -> :timer.sleep(:infinity) end)

  setup config do
    tracker = config.test
    {:ok, _pid} = Phoenix.Tracker.start_link(
      name: tracker,
      pubsub_server: Phoenix.PubSub.Test.PubSub,
      heartbeat_interval: 50,
    )
    {:ok, tracker: tracker}
  end

  test "heartbeats", %{tracker: tracker} do
    Phoenix.PubSub.subscribe(@pubsub, self(), "phx_presence:#{tracker}")
    assert_receive {:pub, :gossip, {:"master@127.0.0.1", _vsn}, _clocks}
    flush()
    assert_receive {:pub, :gossip, {:"master@127.0.0.1", _vsn}, _clocks}
    flush()
    assert_receive {:pub, :gossip, {:"master@127.0.0.1", _vsn}, _clocks}
  end

  test "gossip from unseen node triggers nodeup" do
  end

  test "replicates and locally broadcasts presence_join/leave", %{tracker: tracker} do
    # local joins
    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), "topic")

    assert Tracker.list(tracker, "topic") == %{}
    :ok = Tracker.track(tracker, self(), "topic", "me", %{name: "me"})
    assert_join "topic", "me", %{name: "me"}
    presences = Tracker.list(tracker, "topic")
    assert %{"me" => [%{meta: %{name: "me"}, ref: _}]} = presences
    assert map_size(presences) == 1

    local_presence = spawn_pid()
    :ok = Tracker.track(tracker, local_presence , "topic", "me2", %{name: "me2"})
    assert_join "topic", "me2", %{name: "me2"}
    presences = Tracker.list(tracker, "topic")
    assert %{"me" => [%{meta: %{name: "me"}, ref: _}],
             "me2" => [%{meta: %{name: "me2"}, ref: _}]} = presences
    assert map_size(presences) == 2


    # remote joins
    remote_presence = spawn_pid()
    {_, {:ok, _pid}} = spawn_tracker_on_node(:"slave1@127.0.0.1",
      name: tracker,
      pubsub_server: Phoenix.PubSub.Test.PubSub,
      heartbeat_interval: 50,
    )
    {_, :ok} = track_presence_on_node(
      :"slave1@127.0.0.1", tracker, remote_presence, "topic", "slave1", %{name: "slave1"}
    )
    assert_join "topic", "slave1", %{name: "slave1"}
    presences = Tracker.list(tracker, "topic")
    assert %{"me" => [%{meta: %{name: "me"}, ref: _}],
             "me2" => [%{meta: %{name: "me2"}, ref: _}],
             "slave1" => [%{meta: %{name: "slave1"}, ref: _}]} = presences
    assert map_size(presences) == 3


    # local leaves
    Process.exit(local_presence, :kill)
    assert_leave "topic", "me2", %{name: "me2"}
    presences = Tracker.list(tracker, "topic")
    assert %{"me" => [%{meta: %{name: "me"}, ref: _}],
             "slave1" => [%{meta: %{name: "slave1"}, ref: _}]} = presences
    assert map_size(presences) == 2


    # remote leaves
    Process.exit(remote_presence, :kill)
    assert_leave "topic", "slave1", %{name: "slave1"}
    presences = Tracker.list(tracker, "topic")
    assert %{"me" => [%{meta: %{name: "me"}, ref: _}]} = presences
    assert map_size(presences) == 1
  end

  test "detects nodedown and locally broadcasts leaves", %{tracker: tracker} do
    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), "topic")
    {_, {:ok, slave1_tracker}} = spawn_tracker_on_node(:"slave1@127.0.0.1",
      name: tracker,
      pubsub_server: Phoenix.PubSub.Test.PubSub,
      heartbeat_interval: 50,
    )
    assert Tracker.list(tracker, "topic") == %{}

    local_presence = spawn_pid()
    :ok = Tracker.track(tracker, local_presence , "topic", "local1", %{name: "l1"})
    assert_join "topic", "local1", %{}

    remote_presence = spawn_pid()
    {_, :ok} = track_presence_on_node(
      :"slave1@127.0.0.1", tracker, remote_presence, "topic", "slave1", %{name: "slave1"}
    )
    assert_join "topic", "slave1", %{name: "slave1"}
    presences = Tracker.list(tracker, "topic")
    assert %{"local1" => [_], "slave1" => [_]} = Tracker.list(tracker, "topic")
    assert map_size(presences) == 2


    Process.exit(slave1_tracker, :kill)
    assert_leave "topic", "slave1", %{name: "slave1"}
    presences = Tracker.list(tracker, "topic")
    assert %{"local1" => [_]} = presences
    assert map_size(presences) == 1
  end
end
