defmodule Phoenix.TrackerTest do
  use Phoenix.PubSub.NodeCase
  alias Phoenix.Tracker
  alias Phoenix.Tracker.{Replica, State}

  @master :"master@127.0.0.1"
  @slave1 :"slave1@127.0.0.1"
  @slave2 :"slave2@127.0.0.1"

  setup config do
    tracker = config.test
    {:ok, _pid} = start_tracker(name: tracker)
    {:ok, topic: to_string(config.test), tracker: tracker}
  end

  test "heartbeats", %{tracker: tracker} do
    subscribe_to_tracker(tracker)
    assert_heartbeat from: @master
    flush()
    assert_heartbeat from: @master
    flush()
    assert_heartbeat from: @master
  end

  test "gossip from unseen node triggers nodeup and transfer request",
    %{tracker: tracker, topic: topic} do

    assert list(tracker, topic) == []
    subscribe_to_tracker(tracker)
    drop_gossips(tracker)
    spy_on_tracker(@slave1, self(), tracker)
    start_tracker(@slave1, name: tracker)
    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1", %{})
    flush()
    assert_heartbeat from: @slave1

    resume_gossips(tracker)
    # master sends transfer_req to slave1 after seeing behind
    ref = assert_transfer_req to: @slave1, from: @master
    # slave1 fulfills tranfer request and sends transfer_ack to master
    assert_transfer_ack ref, from: @slave1
    assert_heartbeat to: @slave1, from: @master
    assert [{"slave1", _}] = list(tracker, topic)
  end

  test "requests for transfer collapses clocks",
    %{tracker: tracker, topic: topic} do

    subscribe_to_tracker(tracker)
    subscribe(topic)
    for slave <- [@slave1, @slave2] do
      spy_on_tracker(slave, self(), tracker)
      start_tracker(slave, name: tracker)
      assert_heartbeat to: slave, from: @master
      assert_heartbeat from: slave
    end

    flush()
    drop_gossips(tracker)
    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1", %{})
    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1.2", %{})
    track_presence(@slave2, tracker, spawn_pid(), topic, "slave2", %{})

    # slave1 sends delta broadcast to slave2
    assert_receive {@slave1, {:pub, :heartbeat, {@slave2, _vsn}, %State{mode: :delta}, _clocks}}, @timeout

    # slave2 sends delta broadcast to slave1
    assert_receive {@slave2, {:pub, :heartbeat, {@slave1, _vsn}, %State{mode: :delta}, _clocks}}, @timeout

    flush()
    resume_gossips(tracker)
    # master sends transfer_req to slave with most dominance
    assert_receive {slave, {:pub, :transfer_req, ref, {@master, _vsn}, _state}}, @timeout * 2
    # master does not send transfer_req to other slave, since in dominant slave's future
    refute_received {_other, {:pub, :transfer_req, _ref, {@master, _vsn}, _state}}, @timeout * 2
    # dominant slave fulfills transfer request and sends transfer_ack to master
    assert_receive {:pub, :transfer_ack, ^ref, {^slave, _vsn}, _state}, @timeout

    # wait for local sync
    assert_join ^topic, "slave1", %{}
    assert_join ^topic, "slave1.2", %{}
    assert_join ^topic, "slave2", %{}
    assert_heartbeat from: @slave1
    assert_heartbeat from: @slave2

    assert [{"slave1", _}, {"slave1.2", _}, {"slave2", _}] = list(tracker, topic)
  end

  # TODO split into multiple testscases
  test "tempdowns with nodeups of new vsn, and permdowns",
    %{tracker: tracker, topic: topic} do

    subscribe_to_tracker(tracker)
    subscribe(topic)

    {slave1_node, {:ok, slave1_tracker}} = start_tracker(@slave1, name: tracker)
    {_slave2_node, {:ok, _slave2_tracker}} = start_tracker(@slave2, name: tracker)
    for slave <- [@slave1, @slave2] do
      track_presence(slave, tracker, spawn_pid(), topic, slave, %{})
      assert_join ^topic, ^slave, %{}
    end
    assert_map %{@slave1 => %Replica{status: :up, vsn: vsn_before},
                 @slave2 => %Replica{status: :up}}, replicas(tracker), 2

    # tempdown netsplit
    flush()
    :ok = :sys.suspend(slave1_tracker)
    assert_leave ^topic, @slave1, %{}
    assert_map %{@slave1 => %Replica{status: :down, vsn: ^vsn_before},
                 @slave2 => %Replica{status: :up}}, replicas(tracker), 2
    flush()
    :ok = :sys.resume(slave1_tracker)
    assert_join ^topic, @slave1, %{}
    assert_heartbeat from: @slave1
    assert_map %{@slave1 => %Replica{status: :up, vsn: ^vsn_before},
                 @slave2 => %Replica{status: :up}}, replicas(tracker), 2

    # tempdown crash
    Process.unlink(slave1_node)
    Process.exit(slave1_tracker, :kill)
    assert_leave ^topic, @slave1, %{}
    assert_map %{@slave1 => %Replica{status: :down},
                 @slave2 => %Replica{status: :up}}, replicas(tracker), 2

    # tempdown => nodeup with new vsn
    {slave1_node, {:ok, slave1_tracker}} = start_tracker(@slave1, name: tracker)
    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1-back", %{})
    assert_join ^topic, "slave1-back", %{}
    assert [{@slave2, _}, {"slave1-back", _}] = list(tracker, topic)
    assert_map %{@slave1 => %Replica{status: :up, vsn: new_vsn},
                 @slave2 => %Replica{status: :up}}, replicas(tracker), 2
    assert vsn_before != new_vsn

    # tempdown again
    Process.unlink(slave1_node)
    Process.exit(slave1_tracker, :kill)
    assert_leave ^topic, "slave1-back", %{}
    assert_map %{@slave1 => %Replica{status: :down},
                 @slave2 => %Replica{status: :up}}, replicas(tracker), 2

    # tempdown => permdown
    flush()
    for _ <- 0..trunc(@permdown / @heartbeat), do: assert_heartbeat(from: @master)
    assert_map %{@slave2 => %Replica{status: :up}}, replicas(tracker), 1
  end

  test "replicates and locally broadcasts presence_join/leave",
    %{tracker: tracker, topic: topic} do

    local_presence = spawn_pid()
    remote_pres = spawn_pid()

    # local joins
    subscribe(topic)
    assert list(tracker, topic) == []
    {:ok, _ref} = Tracker.track(tracker, self(), topic, "me", %{name: "me"})
    assert_join ^topic, "me", %{name: "me"}
    assert [{"me", %{name: "me", phx_ref: _}}] = list(tracker, topic)

    {:ok, _ref} = Tracker.track(tracker, local_presence , topic, "me2", %{name: "me2"})
    assert_join ^topic, "me2", %{name: "me2"}
    assert [{"me", %{name: "me", phx_ref: _}},
            {"me2",%{name: "me2", phx_ref: _}}] =
           list(tracker, topic)

    # remote joins
    assert replicas(tracker) == %{}
    start_tracker(@slave1, name: tracker)
    track_presence(@slave1, tracker, remote_pres, topic, "slave1", %{name: "s1"})
    assert_join ^topic, "slave1", %{name: "s1"}
    assert_map %{@slave1 => %Replica{status: :up}}, replicas(tracker), 1
    assert [{"me", %{name: "me", phx_ref: _}},
            {"me2",%{name: "me2", phx_ref: _}},
            {"slave1", %{name: "s1", phx_ref: _}}] =
           list(tracker, topic)

    # local leaves
    Process.exit(local_presence, :kill)
    assert_leave ^topic, "me2", %{name: "me2"}
    assert [{"me", %{name: "me", phx_ref: _}},
            {"slave1", %{name: "s1", phx_ref: _}}] =
           list(tracker, topic)

    # remote leaves
    Process.exit(remote_pres, :kill)
    assert_leave ^topic, "slave1", %{name: "s1"}
    assert [{"me", %{name: "me", phx_ref: _}}] = list(tracker, topic)
  end

  test "detects nodedown and locally broadcasts leaves",
    %{tracker: tracker, topic: topic} do

    local_presence = spawn_pid()
    subscribe(topic)
    {node_pid, {:ok, slave1_tracker}} = start_tracker(@slave1, name: tracker)
    assert list(tracker, topic) == []

    {:ok, _ref} = Tracker.track(tracker, local_presence , topic, "local1", %{name: "l1"})
    assert_join ^topic, "local1", %{}

    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1", %{name: "s1"})
    assert_join ^topic, "slave1", %{name: "s1"}
    assert %{@slave1 => %Replica{status: :up}} = replicas(tracker)
    assert [{"local1", _}, {"slave1", _}] = list(tracker, topic)

    # nodedown
    Process.unlink(node_pid)
    Process.exit(slave1_tracker, :kill)
    assert_leave ^topic, "slave1", %{name: "s1"}
    assert %{@slave1 => %Replica{status: :down}} = replicas(tracker)
    assert [{"local1", _}] = list(tracker, topic)
  end


  test "untrack with no tracked topic is a noop",
    %{tracker: tracker, topic: topic} do
    assert Tracker.untrack(tracker, self(), topic, "foo") == :ok
  end

  test "untrack with topic",
    %{tracker: tracker, topic: topic} do

    Tracker.track(tracker, self(), topic, "user1", %{name: "user1"})
    Tracker.track(tracker, self(), "another:topic", "user2", %{name: "user2"})
    assert [{"user1", %{name: "user1"}}] = list(tracker, topic)
    assert [{"user2", %{name: "user2"}}] = list(tracker, "another:topic")
    assert Tracker.untrack(tracker, self(), topic, "user1") == :ok
    assert [] = list(tracker, topic)
    assert [{"user2", %{name: "user2"}}] = list(tracker, "another:topic")
    assert Process.whereis(tracker) in Process.info(self())[:links]
    assert Tracker.untrack(tracker, self(), "another:topic", "user2") == :ok
    assert [] = list(tracker, "another:topic")
    refute Process.whereis(tracker) in Process.info(self())[:links]
  end

  test "untrack from all topics",
    %{tracker: tracker, topic: topic} do

    Tracker.track(tracker, self(), topic, "user1", %{name: "user1"})
    Tracker.track(tracker, self(), "another:topic", "user2", %{name: "user2"})
    assert [{"user1", %{name: "user1"}}] = list(tracker, topic)
    assert [{"user2", %{name: "user2"}}] = list(tracker, "another:topic")
    assert Process.whereis(tracker) in Process.info(self())[:links]
    assert Tracker.untrack(tracker, self()) == :ok
    assert [] = list(tracker, topic)
    assert [] = list(tracker, "another:topic")
    refute Process.whereis(tracker) in Process.info(self())[:links]
  end

  test "updating presence sends join/leave and phx_ref_prev",
    %{tracker: tracker, topic: topic} do

    subscribe(topic)
    {:ok, _ref} = Tracker.track(tracker, self(), topic, "u1", %{name: "u1"})
    assert [{"u1", %{name: "u1", phx_ref: ref}}] = list(tracker, topic)
    {:ok, _ref} = Tracker.update(tracker, self(), topic, "u1", %{name: "u1-updated"})
    assert_leave ^topic, "u1", %{name: "u1", phx_ref: ^ref}
    assert_join ^topic, "u1", %{name: "u1-updated", phx_ref_prev: ^ref}
  end

  test "updating with no prior presence",
    %{tracker: tracker, topic: topic} do
    assert {:error, :nopresence} = Tracker.update(tracker, self, topic, "u1", %{})
  end

  test "graceful exits with permdown", %{tracker: tracker, topic: topic} do
    subscribe(topic)
    {_node_pid, {:ok, _slave1_tracker}} = start_tracker(@slave1, name: tracker)
    track_presence(@slave1, tracker, spawn_pid(), topic, "slave1", %{name: "s1"})
    assert_join ^topic, "slave1", %{name: "s1"}
    assert %{@slave1 => %Replica{status: :up}} = replicas(tracker)
    assert [{"slave1", _}] = list(tracker, topic)

    # graceful permdown
    {_, :ok} = graceful_permdown(@slave1, tracker)
    assert_leave ^topic, "slave1", %{name: "s1"}
    assert [] = list(tracker, topic)
    assert replicas(tracker) == %{}
  end


  ## Helpers

  def spawn_pid, do: spawn(fn -> :timer.sleep(:infinity) end)

  def replicas(tracker), do: GenServer.call(tracker, :replicas)

  def refute_transfer_req(opts) do
    to = Keyword.fetch!(opts, :to)
    from = Keyword.fetch!(opts, :from)
    refute_receive {^to, {:pub, :transfer_req, _, {^from, _vsn}, _}}, @timeout * 2
  end

  def assert_transfer_req(opts) do
    to = Keyword.fetch!(opts, :to)
    from = Keyword.fetch!(opts, :from)
    assert_receive {^to, {:pub, :transfer_req, ref, {^from, _vsn}, _}}, @timeout * 2
    ref
  end

  def assert_transfer_ack(ref, opts) do
    from = Keyword.fetch!(opts, :from)
    if to = opts[:to] do
      assert_receive {^to, {:pub, :transfer_ack, ^ref, {^from, _vsn}, _state}}, @timeout
    else
      assert_receive {:pub, :transfer_ack, ^ref, {^from, vsn}, _state}, @timeout
    end
  end

  def assert_heartbeat(opts) do
    from = Keyword.fetch!(opts, :from)
    if to = opts[:to] do
      assert_receive {^to, {:pub, :heartbeat, {^from, _vsn}, _delta, _clocks}}, @timeout
    else
      assert_receive {:pub, :heartbeat, {^from, _vsn}, _delta, _clocks}, @timeout
    end
  end

  defp list(tracker, topic) do
    Enum.sort(Tracker.list(tracker, topic))
  end
end
