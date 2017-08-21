defmodule Phoenix.Tracker.IntegrationTest do
  use Phoenix.PubSub.NodeCase
  alias Phoenix.Tracker
  alias Phoenix.Tracker.{Replica, State}

  @primary :"primary@127.0.0.1"
  @node1 :"node1@127.0.0.1"
  @node2 :"node2@127.0.0.1"

  setup config do
    tracker = config.test
    {:ok, tracker_pid} = start_tracker(name: tracker)
    {:ok, topic: to_string(config.test), tracker: tracker, tracker_pid: tracker_pid}
  end

  test "heartbeats", %{tracker: tracker} do
    subscribe_to_tracker(tracker)
    assert_heartbeat from: @primary
    flush()
    assert_heartbeat from: @primary
    flush()
    assert_heartbeat from: @primary
  end

  test "gossip from unseen node triggers nodeup and transfer request",
    %{tracker: tracker, topic: topic} do

    assert list(tracker, topic) == []
    subscribe_to_tracker(tracker)
    drop_gossips(tracker)
    spy_on_tracker(@node1, self(), tracker)
    start_tracker(@node1, name: tracker)
    track_presence(@node1, tracker, spawn_pid(), topic, "node1", %{})
    flush()
    assert_heartbeat from: @node1

    resume_gossips(tracker)
    # primary sends transfer_req to node1 after seeing behind
    ref = assert_transfer_req to: @node1, from: @primary
    # node1 fulfills tranfer request and sends transfer_ack to primary
    assert_transfer_ack ref, from: @node1
    assert_heartbeat to: @node1, from: @primary
    assert [{"node1", _}] = list(tracker, topic)
  end

  test "requests for transfer collapses clocks",
    %{tracker: tracker, topic: topic} do

    subscribe_to_tracker(tracker)
    subscribe(topic)
    for node <- [@node1, @node2] do
      spy_on_tracker(node, self(), tracker)
      start_tracker(node, name: tracker)
      assert_receive {{:replica_up, ^node}, @primary}, @timeout
      assert_receive {{:replica_up, @primary}, ^node}, @timeout
    end
    assert_receive {{:replica_up, @node2}, @node1}, @timeout
    assert_receive {{:replica_up, @node1}, @node2}, @timeout

    flush()
    drop_gossips(tracker)
    track_presence(@node1, tracker, spawn_pid(), topic, "node1", %{})
    track_presence(@node1, tracker, spawn_pid(), topic, "node1.2", %{})
    track_presence(@node2, tracker, spawn_pid(), topic, "node2", %{})

    # node1 sends delta broadcast to node2
    assert_receive {@node1, {:pub, :heartbeat, {@node2, _vsn}, %State{mode: :delta}, _clocks}}, @timeout

    # node2 sends delta broadcast to node1
    assert_receive {@node2, {:pub, :heartbeat, {@node1, _vsn}, %State{mode: :delta}, _clocks}}, @timeout

    flush()
    resume_gossips(tracker)
    # primary sends transfer_req to node with most dominance
    assert_receive {node, {:pub, :transfer_req, ref, {@primary, _vsn}, _state}}, @timeout * 2
    # primary does not send transfer_req to other node, since in dominant node's future
    refute_received {_other, {:pub, :transfer_req, _ref, {@primary, _vsn}, _state}}, @timeout * 2
    # dominant node fulfills transfer request and sends transfer_ack to primary
    assert_receive {:pub, :transfer_ack, ^ref, {^node, _vsn}, _state}, @timeout

    # wait for local sync
    assert_join ^topic, "node1", %{}
    assert_join ^topic, "node1.2", %{}
    assert_join ^topic, "node2", %{}
    assert_heartbeat from: @node1
    assert_heartbeat from: @node2

    assert [{"node1", _}, {"node1.2", _}, {"node2", _}] = list(tracker, topic)
  end

  test "old pids from a node are permdowned when the node comes back up",
    %{tracker: tracker, tracker_pid: tracker_pid, topic: topic} do
    track_presence(@primary, tracker, self(), topic, @primary, %{})
    {node1_node, {:ok, node1_tracker}} = start_tracker(@node1, name: tracker)
    track_presence(@node1, tracker, node1_node, topic, @node1, %{})

    spy_on_tracker(@node1, self(), tracker)
    assert_heartbeat to: @node1, from: @primary

    {node2_node, {:ok, node2_tracker}} = start_tracker(@node2, name: tracker)
    track_presence(@node2, tracker, node2_node, topic, @node2, %{})

    Process.unlink(node1_node)
    Process.exit(node1_tracker, :kill)
    assert_receive {{:replica_permdown, @node1}, @primary}, @permdown * 2

    spy_on_tracker(@node2, self(), tracker)

    {node1_node_new, {:ok, node1_tracker}} = start_tracker(@node1, name: tracker)
    track_presence(@node1, tracker, node1_node_new, topic, @node1, %{})

    flush()
    spy_on_tracker(@node1, self(), tracker)
    assert_heartbeat to: @node2, from: @primary
    assert_heartbeat to: @node1, from: @node2

    refute {@node1, node1_node} in get_values(@primary, tracker_pid)
    refute {@node1, node1_node} in get_values(@node1, node1_tracker)
    refute {@node1, node1_node} in get_values(@node2, node2_tracker)
  end

  # TODO split into multiple testscases
  test "tempdowns with nodeups of new vsn, and permdowns",
    %{tracker: tracker, topic: topic} do

    subscribe_to_tracker(tracker)
    subscribe(topic)

    {node1_node, {:ok, node1_tracker}} = start_tracker(@node1, name: tracker)
    {_node2_node, {:ok, _node2_tracker}} = start_tracker(@node2, name: tracker)
    assert_receive {{:replica_up, @node1}, @node2}, @timeout
    assert_receive {{:replica_up, @node2}, @node1}, @timeout
    for node <- [@node1, @node2] do
      track_presence(node, tracker, spawn_pid(), topic, node, %{})
      assert_join ^topic, ^node, %{}
    end
    assert_map %{@node1 => %Replica{status: :up, vsn: vsn_before},
                 @node2 => %Replica{status: :up}}, replicas(tracker), 2

    # tempdown netsplit
    flush()
    :ok = :sys.suspend(node1_tracker)
    assert_leave ^topic, @node1, %{}
    assert_map %{@node1 => %Replica{status: :down, vsn: ^vsn_before},
                 @node2 => %Replica{status: :up}}, replicas(tracker), 2
    flush()
    :ok = :sys.resume(node1_tracker)
    assert_join ^topic, @node1, %{}
    assert_heartbeat from: @node1
    assert_map %{@node1 => %Replica{status: :up, vsn: ^vsn_before},
                 @node2 => %Replica{status: :up}}, replicas(tracker), 2

    # tempdown crash
    Process.unlink(node1_node)
    Process.exit(node1_tracker, :kill)
    assert_leave ^topic, @node1, %{}
    assert_map %{@node1 => %Replica{status: :down},
                 @node2 => %Replica{status: :up}}, replicas(tracker), 2

    # tempdown => nodeup with new vsn
    flush()
    {node1_node, {:ok, node1_tracker}} = start_tracker(@node1, name: tracker)
    assert_receive {{:replica_up, @node1}, @primary}, @timeout
    assert_receive {{:replica_up, @node1}, @node2}, @timeout
    track_presence(@node1, tracker, spawn_pid(), topic, "node1-back", %{})
    assert_join ^topic, "node1-back", %{}
    assert [{@node2, _}, {"node1-back", _}] = list(tracker, topic)
    assert_map %{@node1 => %Replica{status: :up, vsn: new_vsn},
                 @node2 => %Replica{status: :up}}, replicas(tracker), 2
    assert vsn_before != new_vsn

    # tempdown again
    Process.unlink(node1_node)
    Process.exit(node1_tracker, :kill)
    assert_receive {{:replica_down, @node1}, @primary}, @permdown
    assert_leave ^topic, "node1-back", %{}
    assert_map %{@node1 => %Replica{status: :down},
                 @node2 => %Replica{status: :up}}, replicas(tracker), 2

    # tempdown => permdown
    flush()
    for _ <- 0..trunc(@permdown / @heartbeat), do: assert_heartbeat(from: @primary)
    assert_map %{@node2 => %Replica{status: :up}}, replicas(tracker), 1
  end

  test "getting meta by key", %{tracker: tracker, topic: topic} do
    {:ok, _ref} = Tracker.track(tracker, self(), topic, "me", %{name: "me"})

    assert %{name: "me"} = Tracker.get_by_key(tracker, self(), topic, "me")
  end

  test "node detects and locally broadcasts presence_join/leave",
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
    start_tracker(@node1, name: tracker)
    assert_receive {{:replica_up, @node1}, @primary}, @timeout
    assert_receive {{:replica_up, @primary}, @node1}, @timeout
    track_presence(@node1, tracker, remote_pres, topic, "node1", %{name: "s1"})
    assert_join ^topic, "node1", %{name: "s1"}
    assert_map %{@node1 => %Replica{status: :up}}, replicas(tracker), 1
    assert [{"me", %{name: "me", phx_ref: _}},
            {"me2",%{name: "me2", phx_ref: _}},
            {"node1", %{name: "s1", phx_ref: _}}] =
           list(tracker, topic)

    # local leaves
    Process.exit(local_presence, :kill)
    assert_leave ^topic, "me2", %{name: "me2"}
    assert [{"me", %{name: "me", phx_ref: _}},
            {"node1", %{name: "s1", phx_ref: _}}] =
           list(tracker, topic)

    # remote leaves
    Process.exit(remote_pres, :kill)
    assert_leave ^topic, "node1", %{name: "s1"}
    assert [{"me", %{name: "me", phx_ref: _}}] = list(tracker, topic)
  end

  test "detects nodedown and locally broadcasts leaves",
    %{tracker: tracker, topic: topic} do

    local_presence = spawn_pid()
    subscribe(topic)
    {node_pid, {:ok, node1_tracker}} = start_tracker(@node1, name: tracker)
    assert_receive {{:replica_up, @node1}, @primary}, @timeout
    assert_receive {{:replica_up, @primary}, @node1}, @timeout
    assert list(tracker, topic) == []

    {:ok, _ref} = Tracker.track(tracker, local_presence , topic, "local1", %{name: "l1"})
    assert_join ^topic, "local1", %{}

    track_presence(@node1, tracker, spawn_pid(), topic, "node1", %{name: "s1"})
    assert_join ^topic, "node1", %{name: "s1"}
    assert %{@node1 => %Replica{status: :up}} = replicas(tracker)
    assert [{"local1", _}, {"node1", _}] = list(tracker, topic)

    # nodedown
    Process.unlink(node_pid)
    Process.exit(node1_tracker, :kill)
    assert_receive {{:replica_down, @node1}, @primary}, @permdown
    assert_leave ^topic, "node1", %{name: "s1"}
    assert %{@node1 => %Replica{status: :down}} = replicas(tracker)
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

  test "updating presence sends join/leave and phx_ref_prev with profer diffs if function for update used",
    %{tracker: tracker, topic: topic} do

    subscribe(topic)
    {:ok, _ref} = Tracker.track(tracker, self(), topic, "u1", %{browser: "Chrome", status: "online"})
    assert [{"u1", %{browser: "Chrome", status: "online", phx_ref: ref}}] = list(tracker, topic)
    {:ok, _ref} = Tracker.update(tracker, self(), topic, "u1", fn meta -> Map.put(meta, :status, "away") end)
    assert_leave ^topic, "u1", %{browser: "Chrome", status: "online", phx_ref: ^ref}
    assert_join ^topic, "u1", %{browser: "Chrome", status: "away", phx_ref_prev: ^ref}
  end

  test "updating with no prior presence", %{tracker: tracker, topic: topic} do
    assert {:error, :nopresence} = Tracker.update(tracker, self(), topic, "u1", %{})
  end

  test "duplicate tracking", %{tracker: tracker, topic: topic} do
    pid = self()
    assert {:ok, _ref} = Tracker.track(tracker, pid, topic, "u1", %{})
    assert {:error, {:already_tracked, ^pid, ^topic, "u1"}} =
           Tracker.track(tracker, pid, topic, "u1", %{})
    assert {:ok, _ref} = Tracker.track(tracker, pid, "another:topic", "u1", %{})
    assert {:ok, _ref} = Tracker.track(tracker, pid, topic, "anotherkey", %{})

    assert :ok = Tracker.untrack(tracker, pid, topic, "u1")
    assert :ok = Tracker.untrack(tracker, pid, "another:topic", "u1")
    assert :ok = Tracker.untrack(tracker, pid, topic, "anotherkey")
  end

  test "graceful exits with permdown", %{tracker: tracker, topic: topic} do
    subscribe(topic)
    {_node_pid, {:ok, _node1_tracker}} = start_tracker(@node1, name: tracker)
    assert_receive {{:replica_up, @node1}, @primary}, @timeout
    assert_receive {{:replica_up, @primary}, @node1}, @timeout
    track_presence(@node1, tracker, spawn_pid(), topic, "node1", %{name: "s1"})
    assert_join ^topic, "node1", %{name: "s1"}
    assert %{@node1 => %Replica{status: :up}} = replicas(tracker)
    assert [{"node1", _}] = list(tracker, topic)

    # graceful permdown
    {_, :ok} = graceful_permdown(@node1, tracker)
    assert_leave ^topic, "node1", %{name: "s1"}
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
      assert_receive {:pub, :transfer_ack, ^ref, {^from, _vsn}, _state}, @timeout
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
