defmodule Phoenix.TrackerTest do
  use Phoenix.PubSub.NodeCase
  alias Phoenix.Tracker
  alias Phoenix.Tracker.VNode

  @pubsub Phoenix.PubSub.Test.PubSub
  @slave1 :"slave1@127.0.0.1"
  @master :"master@127.0.0.1"

  def spawn_pid, do: spawn(fn -> :timer.sleep(:infinity) end)

  setup config do
    tracker = config.test
    {:ok, _pid} = Phoenix.Tracker.start_link(
      name: tracker,
      pubsub_server: Phoenix.PubSub.Test.PubSub,
      heartbeat_interval: 50,
    )
    {:ok, topic: config.test, tracker: tracker}
  end

  test "heartbeats", %{tracker: tracker} do
    Phoenix.PubSub.subscribe(@pubsub, self(), "phx_presence:#{tracker}")
    assert_receive {:pub, :gossip, %VNode{name: @master}, _clocks}
    flush()
    assert_receive {:pub, :gossip, %VNode{name: @master}, _clocks}
    flush()
    assert_receive {:pub, :gossip, %VNode{name: @master}, _clocks}
  end

  # defp assert_local_track(pid, topic, key, meta) do
  #   presences_before = Tracker.list(tracker, topic)
  #   :ok = Tracker.track(tracker, pid, topic, key, meta)
  #   assert_join topic, key, meta
  #   presences = Tracker.list(tracker, topic)
  #   assert %{^key => [%{meta: ^meta, ref: _}]} = presences
  #   assert map_size(presences) == map_size(presences_before) + 1

  #   presences
  # end

  test "gossip from unseen node triggers nodeup and transfer request",
    %{tracker: tracker, topic: topic} do

    # TODO assert nodeup (some way, cleanly)
    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), "phx_presence:#{tracker}")
    spy_on_pubsub(@slave1, @pubsub, self(), "phx_presence:#{tracker}")

    remote_presence = spawn_pid()
    {_, {:ok, _pid}} = spawn_tracker_on_node(@slave1,
      name: tracker,
      pubsub_server: Phoenix.PubSub.Test.PubSub,
      heartbeat_interval: 50,
    )
    # does not gossip until slave1's clock bumps
    refute_receive {@slave1, {:pub, :transfer_req, _, %VNode{name: @master}, _}}

    {_, :ok} = track_presence_on_node(
      @slave1, tracker, remote_presence, topic, "slave1", %{name: "slave1"}
    )
    # master sends transfer_req to slave1
    assert_receive {@slave1, {:pub, :transfer_req, ref, %VNode{name: @master}, _state}}
    # slave1 fulfills tranfer requests and sends transfer_ack to master
    assert_receive {:pub, :transfer_ack, ^ref, %VNode{name: @slave1}, _state}
  end

  test "nodes are eventually permdown'd following nodedown period" do
    # TODO
  end

  test "replicates and locally broadcasts presence_join/leave",
    %{tracker: tracker, topic: topic} do

    # local joins
    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), topic)

    assert Tracker.list(tracker, topic) == %{}
    :ok = Tracker.track(tracker, self(), topic, "me", %{name: "me"})
    assert_join ^topic, "me", %{name: "me"}
    presences = Tracker.list(tracker, topic)
    assert %{"me" => [%{meta: %{name: "me"}, ref: _}]} = presences
    assert map_size(presences) == 1

    local_presence = spawn_pid()
    :ok = Tracker.track(tracker, local_presence , topic, "me2", %{name: "me2"})
    assert_join ^topic, "me2", %{name: "me2"}
    presences = Tracker.list(tracker, topic)
    assert %{"me" => [%{meta: %{name: "me"}, ref: _}],
             "me2" => [%{meta: %{name: "me2"}, ref: _}]} = presences
    assert map_size(presences) == 2


    # remote joins
    remote_presence = spawn_pid()
    {_, {:ok, _pid}} = spawn_tracker_on_node(@slave1,
      name: tracker,
      pubsub_server: Phoenix.PubSub.Test.PubSub,
      heartbeat_interval: 50,
    )
    {_, :ok} = track_presence_on_node(
      @slave1, tracker, remote_presence, topic, "slave1", %{name: "slave1"}
    )
    assert_join ^topic, "slave1", %{name: "slave1"}
    presences = Tracker.list(tracker, topic)
    assert %{"me" => [%{meta: %{name: "me"}, ref: _}],
             "me2" => [%{meta: %{name: "me2"}, ref: _}],
             "slave1" => [%{meta: %{name: "slave1"}, ref: _}]} = presences
    assert map_size(presences) == 3


    # local leaves
    Process.exit(local_presence, :kill)
    assert_leave ^topic, "me2", %{name: "me2"}
    presences = Tracker.list(tracker, topic)
    assert %{"me" => [%{meta: %{name: "me"}, ref: _}],
             "slave1" => [%{meta: %{name: "slave1"}, ref: _}]} = presences
    assert map_size(presences) == 2


    # remote leaves
    Process.exit(remote_presence, :kill)
    assert_leave ^topic, "slave1", %{name: "slave1"}
    presences = Tracker.list(tracker, topic)
    assert %{"me" => [%{meta: %{name: "me"}, ref: _}]} = presences
    assert map_size(presences) == 1
  end

  test "detects nodedown and locally broadcasts leaves",
    %{tracker: tracker, topic: topic} do

    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), topic)
    {node_pid, {:ok, slave1_tracker}} = spawn_tracker_on_node(@slave1,
      name: tracker,
      pubsub_server: Phoenix.PubSub.Test.PubSub,
      heartbeat_interval: 50,
    )
    assert Tracker.list(tracker, topic) == %{}

    local_presence = spawn_pid()
    :ok = Tracker.track(tracker, local_presence , topic, "local1", %{name: "l1"})
    assert_join ^topic, "local1", %{}

    remote_presence = spawn_pid()
    {_, :ok} = track_presence_on_node(
      @slave1, tracker, remote_presence, topic, "slave1", %{name: "slave1"}
    )
    assert_join ^topic, "slave1", %{name: "slave1"}
    presences = Tracker.list(tracker, topic)
    assert %{"local1" => _, "slave1" => _} = presences
    assert map_size(presences) == 2

    # nodedown
    Process.unlink(node_pid)
    Process.exit(slave1_tracker, :kill)
    assert_leave ^topic, "slave1", %{name: "slave1"}
    presences = Tracker.list(tracker, topic)
    assert %{"local1" => _} = presences
    assert map_size(presences) == 1
  end
end
