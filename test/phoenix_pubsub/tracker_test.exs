defmodule Phoenix.TrackerTest do
  use Phoenix.PubSub.NodeCase
  alias Phoenix.Tracker
  alias Phoenix.Tracker.VNode

  @master :"master@127.0.0.1"
  @slave1 :"slave1@127.0.0.1"
  @slave2 :"slave2@127.0.0.1"
  @heartbeat 25
  @permdown 1000
  @timeout 100

  setup config do
    tracker = config.test
    {:ok, _pid} = start_tracker(name: tracker)
    {:ok, topic: config.test, tracker: tracker}
  end

  test "heartbeats", %{tracker: tracker} do
    subscribe_to_tracker(self(), tracker)
    assert_gossip from: @master
    flush()
    assert_gossip from: @master
    flush()
    assert_gossip from: @master
  end

  test "gossip from unseen node triggers nodeup and transfer request",
    %{tracker: tracker, topic: topic} do

    assert Tracker.list(tracker, topic) == %{}
    subscribe_to_tracker(self(), tracker)
    spy_on_tracker(@slave1, self(), tracker)
    start_tracker(@slave1, name: tracker)

    # does not gossip until slave1's clock bumps
    refute_transfer_req to: @slave1, from: @master
    assert_map %{@slave1 => %VNode{status: :up}}, vnodes(tracker), 1

    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1", %{})
    # master sends transfer_req to slave1
    ref = assert_transfer_req to: @slave1, from: @master
    # slave1 fulfills tranfer request and sends transfer_ack to master
    assert_transfer_ack ref, from: @slave1
    assert %{"slave1" => _} = Tracker.list(tracker, topic)
  end

  test "requests for transfer collapses clocks",
    %{tracker: tracker, topic: topic} do

    subscribe_to_tracker(self(), tracker)
    subscribe(self(), topic)
    for slave <- [@slave1, @slave2] do
      spy_on_tracker(slave, self(), tracker)
      start_tracker(slave, name: tracker)
      assert_gossip to: slave, from: @master
    end
    :ok = :sys.suspend(tracker)
    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1", %{})
    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1.2", %{})
    track_presence(@slave2, tracker, spawn_pid(), topic, "slave2", %{})

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

    assert_map %{"slave1" => _, "slave1.2" => _, "slave2" => _},
               Tracker.list(tracker, topic), 3
  end

  # TODO split into multiple testscases
  test "tempdowns with nodeups of new vsn, and permdowns",
    %{tracker: tracker, topic: topic} do

    subscribe_to_tracker(self(), tracker)
    subscribe(self(), topic)

    {slave1_node, {:ok, slave1_tracker}} = start_tracker(@slave1, name: tracker)
    {_slave2_node, {:ok, _slave2_tracker}} = start_tracker(@slave2, name: tracker)
    for slave <- [@slave1, @slave2] do
      track_presence(slave, tracker, spawn_pid(), topic, slave, %{})
      assert_join ^topic, ^slave, %{}
    end
    assert_map %{@slave1 => %VNode{status: :up, vsn: vsn_before},
                 @slave2 => %VNode{status: :up}}, vnodes(tracker), 2

    # tempdown netsplit
    flush()
    :ok = :sys.suspend(slave1_tracker)
    assert_leave ^topic, @slave1, %{}
    assert_map %{@slave1 => %VNode{status: :down, vsn: ^vsn_before},
                 @slave2 => %VNode{status: :up}}, vnodes(tracker), 2
    :ok = :sys.resume(slave1_tracker)
    assert_join ^topic, @slave1, %{}
    assert_map %{@slave1 => %VNode{status: :up, vsn: ^vsn_before},
                 @slave2 => %VNode{status: :up}}, vnodes(tracker), 2

    # tempdown crash
    Process.unlink(slave1_node)
    Process.exit(slave1_tracker, :kill)
    assert_leave ^topic, @slave1, %{}
    assert_map %{@slave1 => %VNode{status: :down},
                 @slave2 => %VNode{status: :up}}, vnodes(tracker), 2

    # tempdown => nodeup with new vsn
    {slave1_node, {:ok, slave1_tracker}} = start_tracker(@slave1, name: tracker)
    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1-back", %{})
    assert_join ^topic, "slave1-back", %{}
    assert_map %{@slave2 => _, "slave1-back" => _}, Tracker.list(tracker, topic), 2
    assert_map %{@slave1 => %VNode{status: :up, vsn: new_vsn},
                 @slave2 => %VNode{status: :up}}, vnodes(tracker), 2
    assert vsn_before != new_vsn

    # tempdown again
    Process.unlink(slave1_node)
    Process.exit(slave1_tracker, :kill)
    assert_leave ^topic, "slave1-back", %{}
    assert_map %{@slave1 => %VNode{status: :down},
                 @slave2 => %VNode{status: :up}}, vnodes(tracker), 2

    # tempdown => permdown
    flush()
    for _ <- 0..trunc(@permdown / @heartbeat), do: assert_gossip(from: @master)
    assert_map %{@slave2 => %VNode{status: :up}}, vnodes(tracker), 1
  end

  test "replicates and locally broadcasts presence_join/leave",
    %{tracker: tracker, topic: topic} do

    local_presence = spawn_pid()
    remote_pres = spawn_pid()

    # local joins
    subscribe(self(), topic)
    assert Tracker.list(tracker, topic) == %{}
    :ok = Tracker.track(tracker, self(), topic, "me", %{name: "me"})
    assert_join ^topic, "me", %{name: "me"}
    assert_map %{"me" => [%{meta: %{name: "me"}, ref: _}]}, Tracker.list(tracker, topic), 1

    :ok = Tracker.track(tracker, local_presence , topic, "me2", %{name: "me2"})
    assert_join ^topic, "me2", %{name: "me2"}
    assert_map %{"me" => [%{meta: %{name: "me"}, ref: _}],
                 "me2" => [%{meta: %{name: "me2"}, ref: _}]},
               Tracker.list(tracker, topic), 2

    # remote joins
    assert vnodes(tracker) == %{}
    start_tracker(@slave1, name: tracker)
    track_presence(@slave1, tracker, remote_pres, topic, "slave1", %{name: "s1"})
    assert_join ^topic, "slave1", %{name: "s1"}
    assert_map %{@slave1 => %VNode{status: :up}}, vnodes(tracker), 1
    assert_map %{"me" => [%{meta: %{name: "me"}, ref: _}],
                 "me2" => [%{meta: %{name: "me2"}, ref: _}],
                 "slave1" => [%{meta: %{name: "s1"}, ref: _}]},
                 Tracker.list(tracker, topic), 3

    # local leaves
    Process.exit(local_presence, :kill)
    assert_leave ^topic, "me2", %{name: "me2"}
    assert_map %{"me" => [%{meta: %{name: "me"}, ref: _}],
                 "slave1" => [%{meta: %{name: "s1"}, ref: _}]},
               Tracker.list(tracker, topic), 2

    # remote leaves
    Process.exit(remote_pres, :kill)
    assert_leave ^topic, "slave1", %{name: "s1"}
    assert_map %{"me" => [%{meta: %{name: "me"}}]}, Tracker.list(tracker, topic), 1
  end

  test "detects nodedown and locally broadcasts leaves",
    %{tracker: tracker, topic: topic} do

    local_presence = spawn_pid()
    subscribe(self(), topic)
    {node_pid, {:ok, slave1_tracker}} = start_tracker(@slave1, name: tracker)
    assert Tracker.list(tracker, topic) == %{}

    :ok = Tracker.track(tracker, local_presence , topic, "local1", %{name: "l1"})
    assert_join ^topic, "local1", %{}

    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1", %{name: "s1"})
    assert_join ^topic, "slave1", %{name: "s1"}
    assert %{@slave1 => %VNode{status: :up}} = vnodes(tracker)
    assert_map %{"local1" => _, "slave1" => _}, Tracker.list(tracker, topic), 2

    # nodedown
    Process.unlink(node_pid)
    Process.exit(slave1_tracker, :kill)
    assert_leave ^topic, "slave1", %{name: "s1"}
    assert %{@slave1 => %VNode{status: :down}} = vnodes(tracker)
    assert_map %{"local1" => _}, Tracker.list(tracker, topic), 1
  end


  ## Helpers

  def spawn_pid, do: spawn(fn -> :timer.sleep(:infinity) end)

  def vnodes(tracker), do: GenServer.call(tracker, :vnodes)

  def refute_transfer_req(opts) do
    to = Keyword.fetch!(opts, :to)
    from = Keyword.fetch!(opts, :from)
    refute_receive {^to, {:pub, :transfer_req, _, %VNode{name: ^from}, _}}
  end

  def assert_transfer_req(opts) do
    to = Keyword.fetch!(opts, :to)
    from = Keyword.fetch!(opts, :from)
    assert_receive {^to, {:pub, :transfer_req, ref, %VNode{name: ^from}, _}}
    ref
  end

  def assert_transfer_ack(ref, opts) do
    from = Keyword.fetch!(opts, :from)
    if to = opts[:to] do
      assert_receive {^to, {:pub, :transfer_ack, ^ref, %VNode{name: ^from}, _state}}, @timeout
    else
      assert_receive {:pub, :transfer_ack, ^ref, %VNode{name: ^from}, _state}, @timeout
    end
  end

  def assert_gossip(opts) do
    from = Keyword.fetch!(opts, :from)
    if to = opts[:to] do
      assert_receive {^to, {:pub, :gossip, %VNode{name: ^from}, _clocks}}, @timeout
    else
      assert_receive {:pub, :gossip, %VNode{name: ^from}, _clocks}, @timeout
    end
  end
end
