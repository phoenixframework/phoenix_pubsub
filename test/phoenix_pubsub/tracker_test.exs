defmodule Phoenix.TrackerTest do
  use Phoenix.PubSub.NodeCase
  alias Phoenix.Tracker
  alias Phoenix.Tracker.VNode

  @pubsub Phoenix.PubSub.Test.PubSub
  @master :"master@127.0.0.1"
  @slave1 :"slave1@127.0.0.1"
  @slave2 :"slave2@127.0.0.1"
  @heartbeat 25
  @permdown 1000
  @timeout @heartbeat * 4

  def spawn_pid, do: spawn(fn -> :timer.sleep(:infinity) end)

  def vnodes(tracker), do: GenServer.call(tracker, :vnodes)

  setup config do
    tracker = config.test
    {:ok, _pid} = Phoenix.Tracker.start_link(
      name: tracker,
      pubsub_server: @pubsub,
      heartbeat_interval: @heartbeat,
      permdown_interval: @permdown,
    )
    {:ok, topic: config.test, tracker: tracker}
  end

  test "heartbeats", %{tracker: tracker} do
    Phoenix.PubSub.subscribe(@pubsub, self(), "phx_presence:#{tracker}")
    assert_receive {:pub, :gossip, %VNode{name: @master}, _clocks}, @timeout
    flush()
    assert_receive {:pub, :gossip, %VNode{name: @master}, _clocks}, @timeout
    flush()
    assert_receive {:pub, :gossip, %VNode{name: @master}, _clocks}, @timeout
  end

  test "gossip from unseen node triggers nodeup and transfer request",
    %{tracker: tracker, topic: topic} do

    # TODO assert nodeup (some way, cleanly)
    assert Tracker.list(tracker, topic) == %{}
    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), "phx_presence:#{tracker}")
    spy_on_pubsub(@slave1, @pubsub, self(), "phx_presence:#{tracker}")

    remote_presence = spawn_pid()
    {_, {:ok, _pid}} = spawn_tracker_on_node(@slave1,
      name: tracker,
      pubsub_server: @pubsub,
      heartbeat_interval: @heartbeat,
    )
    # does not gossip until slave1's clock bumps
    refute_receive {@slave1, {:pub, :transfer_req, _, %VNode{name: @master}, _}}
    assert %{@slave1 => %VNode{status: :up}} = vnodes(tracker)

    {_, :ok} = track_presence_on_node(
      @slave1, tracker, remote_presence, topic, "slave1", %{name: "slave1"}
    )
    # master sends transfer_req to slave1
    assert_receive {@slave1, {:pub, :transfer_req, ref, %VNode{name: @master}, _state}}, @timeout
    # slave1 fulfills tranfer request and sends transfer_ack to master
    assert_receive {:pub, :transfer_ack, ^ref, %VNode{name: @slave1}, _state}, @timeout
    assert %{"slave1" => _} = Tracker.list(tracker, topic)
  end

  test "requests for transfer collapses clocks",
    %{tracker: tracker, topic: topic} do

    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), "phx_presence:#{tracker}")
    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), topic)
    for slave <- [@slave1, @slave2] do
      spy_on_pubsub(slave, @pubsub, self(), "phx_presence:#{tracker}")
      {_, {:ok, _pid}} = spawn_tracker_on_node(slave,
        name: tracker,
        pubsub_server: @pubsub,
        heartbeat_interval: @heartbeat,
        permdown_interval: @permdown,
      )
      assert_receive {^slave, {:pub, :gossip, %VNode{name: @master}, _clocks}}
    end
    :ok = :sys.suspend(tracker)
    {_, :ok} = track_presence_on_node(@slave1, tracker, spawn_pid(), topic, "slave1", %{})
    {_, :ok} = track_presence_on_node(@slave1, tracker, spawn_pid(), topic, "slave1.2", %{})
    {_, :ok} = track_presence_on_node(@slave2, tracker, spawn_pid(), topic, "slave2", %{})

    # slave1 sends transfer_req to slave2
    assert_receive {slave1, {:pub, :transfer_req, ref, %VNode{name: slave2}, _state}}, @timeout
    # slave2 fulfills tranfer request and sends transfer_ack to slave1
    assert_receive {^slave2, {:pub, :transfer_ack, ^ref, %VNode{name: ^slave1}, _state}}, @timeout

    :ok = :sys.resume(tracker)
    # master sends transfer_req to slave with most dominance
    assert_receive {slave1, {:pub, :transfer_req, ref, %VNode{name: @master}, _state}}, @timeout
    # master does not send transfer_req to other slave, since in dominant slave's future
    refute_received {_other, {:pub, :transfer_req, _ref, %VNode{name: @master}, _state}}, @timeout
    # dominant slave fulfills transfer request and sends transfer_ack to master
    assert_receive {:pub, :transfer_ack, ^ref, %VNode{name: ^slave1}, _state}, @timeout

    # wait for local sync
    assert_join ^topic, "slave1", %{}
    assert_join ^topic, "slave1.2", %{}
    assert_join ^topic, "slave2", %{}

    presences = Phoenix.Tracker.list(tracker, topic)
    assert %{"slave1" => _, "slave1.2" => _, "slave2" => _} = presences
    assert map_size(presences) == 3
  end

  test "tempdowns with nodeups of new vsn, and permdowns",
    %{tracker: tracker, topic: topic} do

    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), "phx_presence:#{tracker}")
    :ok = Phoenix.PubSub.subscribe(@pubsub, self(), topic)
    {slave1_node, {:ok, slave1_tracker}} = spawn_tracker_on_node(@slave1,
      name: tracker,
      pubsub_server: @pubsub,
      heartbeat_interval: @heartbeat,
    )
    {_slave2_node, {:ok, _slave2_tracker}} = spawn_tracker_on_node(@slave2,
      name: tracker,
      pubsub_server: @pubsub,
      heartbeat_interval: @heartbeat,
    )
    for slave <- [@slave1, @slave2] do
      pid = spawn_pid()
      {_, :ok} = track_presence_on_node(slave, tracker, pid, topic, slave, %{})
      assert_join ^topic, ^slave, %{}
    end
    assert %{@slave1 => %VNode{status: :up, vsn: vsn_before},
             @slave2 => %VNode{status: :up}} = vnodes(tracker)

    # tempdown netsplit
    flush()
    :ok = :sys.suspend(slave1_tracker)
    assert_leave ^topic, @slave1, %{}
    assert %{@slave1 => %VNode{status: :down, vsn: ^vsn_before},
             @slave2 => %VNode{status: :up}} = vnodes(tracker)
    :ok = :sys.resume(slave1_tracker)
    assert_join ^topic, @slave1, %{}
    assert %{@slave1 => %VNode{status: :up, vsn: ^vsn_before},
             @slave2 => %VNode{status: :up}} = vnodes(tracker)

    # tempdown crash
    Process.unlink(slave1_node)
    Process.exit(slave1_tracker, :kill)
    assert_leave ^topic, @slave1, %{}
    assert %{@slave1 => %VNode{status: :down},
             @slave2 => %VNode{status: :up}} = vnodes(tracker)

    # tempdown => nodeup with new vsn
    {slave1_node, {:ok, slave1_tracker}} = spawn_tracker_on_node(@slave1,
      name: tracker,
      pubsub_server: @pubsub,
      heartbeat_interval: @heartbeat,
    )
    pid = spawn_pid()
    {_, :ok} = track_presence_on_node(@slave1, tracker, pid, topic, "slave1-back", %{})
    assert_join ^topic, "slave1-back", %{}
    presences = Tracker.list(tracker, topic)
    assert %{@slave2 => _, "slave1-back" => _} = presences
    assert map_size(presences) == 2
    assert %{@slave1 => %VNode{status: :up, vsn: new_vsn},
             @slave2 => %VNode{status: :up}} = vnodes(tracker)
    assert vsn_before != new_vsn

    # tempdown again
    Process.unlink(slave1_node)
    Process.exit(slave1_tracker, :kill)
    assert_leave ^topic, "slave1-back", %{}
    assert %{@slave1 => %VNode{status: :down},
             @slave2 => %VNode{status: :up}} = vnodes(tracker)

    # tempdown => permdown
    flush()
    for _ <- 0..trunc(@permdown / @heartbeat) do
      assert_receive {:pub, :gossip, %VNode{name: @master}, _clocks}, @timeout
    end
    vnodes = vnodes(tracker)
    assert %{@slave2 => %VNode{status: :up}} = vnodes
    assert map_size(vnodes) == 1
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
    assert vnodes(tracker) == %{}
    remote_presence = spawn_pid()
    {_, {:ok, _pid}} = spawn_tracker_on_node(@slave1,
      name: tracker,
      pubsub_server: @pubsub,
      heartbeat_interval: @heartbeat,
    )
    {_, :ok} = track_presence_on_node(
      @slave1, tracker, remote_presence, topic, "slave1", %{name: "slave1"}
    )
    assert_join ^topic, "slave1", %{name: "slave1"}
    assert %{@slave1 => %VNode{status: :up}} = vnodes(tracker)
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
      pubsub_server: @pubsub,
      heartbeat_interval: @heartbeat,
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
    assert %{@slave1 => %VNode{status: :up}} = vnodes(tracker)
    presences = Tracker.list(tracker, topic)
    assert %{"local1" => _, "slave1" => _} = presences
    assert map_size(presences) == 2

    # nodedown
    Process.unlink(node_pid)
    Process.exit(slave1_tracker, :kill)
    assert_leave ^topic, "slave1", %{name: "slave1"}
    assert %{@slave1 => %VNode{status: :down}} = vnodes(tracker)
    presences = Tracker.list(tracker, topic)
    assert %{"local1" => _} = presences
    assert map_size(presences) == 1
  end
end
