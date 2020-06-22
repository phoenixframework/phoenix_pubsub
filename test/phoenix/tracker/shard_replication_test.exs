defmodule Phoenix.Tracker.ShardReplicationTest do
  use Phoenix.PubSub.NodeCase
  alias Phoenix.Tracker.{Replica, Shard, State}

  @primary :"primary@127.0.0.1"
  @node1 :"node1@127.0.0.1"
  @node2 :"node2@127.0.0.1"

  setup config do
    tracker = config.test

    tracker_opts = config |> Map.get(:tracker_opts, []) |> Keyword.put_new(:name, tracker)
    {:ok, shard_pid} = start_shard(tracker_opts)

    {:ok,
     topic: to_string(tracker),
     shard: shard_name(tracker),
     shard_pid: shard_pid,
     tracker: tracker,
     tracker_opts: tracker_opts}
  end

  test "heartbeats", %{shard: shard} do
    subscribe_to_server(shard)
    assert_heartbeat from: @primary
    flush()
    assert_heartbeat from: @primary
    flush()
    assert_heartbeat from: @primary
  end

  test "gossip from unseen node triggers nodeup and transfer request",
    %{shard: shard, topic: topic, tracker: tracker} do

    assert list(shard, topic) == []
    subscribe_to_server(shard)
    drop_gossips(shard)
    spy_on_server(@node1, self(), shard)
    start_shard(@node1, name: tracker)
    track_presence(@node1, shard, spawn_pid(), topic, "node1", %{})
    flush()
    assert_heartbeat from: @node1

    resume_gossips(shard)
    # primary sends transfer_req to node1 after seeing behind
    ref = assert_transfer_req to: @node1, from: @primary
    # node1 fulfills tranfer request and sends transfer_ack to primary
    assert_transfer_ack ref, from: @node1
    assert_heartbeat to: @node1, from: @primary

    # small delay to ensure transfer_ack has been processed before calling list
    :timer.sleep(10)
    assert [{"node1", _}] = list(shard, topic)
  end

  test "requests for transfer collapses clocks",
    %{shard: shard, topic: topic, tracker: tracker} do

    subscribe_to_server(shard)
    subscribe(topic)
    for node <- [@node1, @node2] do
      spy_on_server(node, self(), shard)
      start_shard(node, name: tracker)
      assert_receive {{:replica_up, ^node}, @primary}, @timeout
      assert_receive {{:replica_up, @primary}, ^node}, @timeout
    end
    assert_receive {{:replica_up, @node2}, @node1}, @timeout
    assert_receive {{:replica_up, @node1}, @node2}, @timeout

    flush()
    drop_gossips(shard)
    track_presence(@node1, shard, spawn_pid(), topic, "node1", %{})
    track_presence(@node1, shard, spawn_pid(), topic, "node1.2", %{})
    track_presence(@node2, shard, spawn_pid(), topic, "node2", %{})

    # node1 sends delta broadcast to node2
    assert_receive {@node1, {:pub, :heartbeat, {@node2, _vsn}, %State{mode: :delta}, _clocks}}, @timeout

    # node2 sends delta broadcast to node1
    assert_receive {@node2, {:pub, :heartbeat, {@node1, _vsn}, %State{mode: :delta}, _clocks}}, @timeout

    flush()
    resume_gossips(shard)
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

    # small delay to ensure transfer_ack has been processed before calling list
    :timer.sleep(10)
    assert [{"node1", _}, {"node1.2", _}, {"node2", _}] = list(shard, topic)
  end

  test "old pids from a node are permdowned when the node comes back up",
    %{shard: shard, shard_pid: shard_pid, topic: topic, tracker: tracker} do
    track_presence(@primary, shard, self(), topic, @primary, %{})
    {node1_node, {:ok, node1_shard}} = start_shard(@node1, name: tracker)
    track_presence(@node1, shard, node1_node, topic, @node1, %{})

    spy_on_server(@node1, self(), shard)
    assert_heartbeat to: @node1, from: @primary

    {node2_node, {:ok, node2_shard}} = start_shard(@node2, name: tracker)
    track_presence(@node2, shard, node2_node, topic, @node2, %{})

    Process.unlink(node1_node)
    Process.exit(node1_shard, :kill)
    assert_receive {{:replica_permdown, @node1}, @primary}, @permdown * 2

    spy_on_server(@node2, self(), shard)

    {node1_node_new, {:ok, node1_shard}} = start_shard(@node1, name: tracker)
    track_presence(@node1, shard, node1_node_new, topic, @node1, %{})

    flush()
    spy_on_server(@node1, self(), shard)
    assert_heartbeat to: @node2, from: @primary
    assert_heartbeat to: @node1, from: @node2

    refute {@node1, node1_node} in get_values(@primary, shard_pid)
    refute {@node1, node1_node} in get_values(@node1, node1_shard)
    refute {@node1, node1_node} in get_values(@node2, node2_shard)
  end

  # TODO split into multiple testscases
  test "tempdowns with nodeups of new vsn, and permdowns",
    %{shard: shard, topic: topic, tracker: tracker} do

    subscribe_to_server(shard)
    subscribe(topic)

    {node1_node, {:ok, node1_server}} = start_shard(@node1, name: tracker)
    {_node2_node, {:ok, _node2_server}} = start_shard(@node2, name: tracker)
    for node <- [@node1, @node2] do
      track_presence(node, shard, spawn_pid(), topic, node, %{})
      assert_join ^topic, ^node, %{}
    end
    assert_map %{@node1 => %Replica{status: :up, vsn: vsn_before},
                 @node2 => %Replica{status: :up}}, replicas(shard), 2

    # tempdown netsplit
    flush()
    :ok = :sys.suspend(node1_server)
    assert_leave ^topic, @node1, %{}
    assert_map %{@node1 => %Replica{status: :down, vsn: ^vsn_before},
                 @node2 => %Replica{status: :up}}, replicas(shard), 2
    flush()
    :ok = :sys.resume(node1_server)
    assert_join ^topic, @node1, %{}
    assert_heartbeat from: @node1
    assert_map %{@node1 => %Replica{status: :up, vsn: ^vsn_before},
                 @node2 => %Replica{status: :up}}, replicas(shard), 2

    # tempdown crash
    Process.unlink(node1_node)
    Process.exit(node1_server, :kill)
    assert_leave ^topic, @node1, %{}
    assert_map %{@node1 => %Replica{status: :down},
                 @node2 => %Replica{status: :up}}, replicas(shard), 2

    # tempdown => nodeup with new vsn
    {node1_node, {:ok, node1_server}} = start_shard(@node1, name: tracker)
    track_presence(@node1, shard, spawn_pid(), topic, "node1-back", %{})
    assert_join ^topic, "node1-back", %{}
    assert [{@node2, _}, {"node1-back", _}] = list(shard, topic)
    assert_map %{@node1 => %Replica{status: :up, vsn: new_vsn},
                 @node2 => %Replica{status: :up}}, replicas(shard), 2
    assert vsn_before != new_vsn

    # tempdown again
    Process.unlink(node1_node)
    Process.exit(node1_server, :kill)
    assert_leave ^topic, "node1-back", %{}
    assert_map %{@node1 => %Replica{status: :down},
                 @node2 => %Replica{status: :up}}, replicas(shard), 2

    # tempdown => permdown
    flush()
    for _ <- 0..trunc(@permdown / @heartbeat), do: assert_heartbeat(from: @primary)
    assert_map %{@node2 => %Replica{status: :up}}, replicas(shard), 1
  end

  test "node detects and locally broadcasts presence_join/leave",
    %{shard: shard, topic: topic, tracker: tracker} do

    local_presence = spawn_pid()
    remote_pres = spawn_pid()

    # local joins
    subscribe(topic)
    assert list(shard, topic) == []
    {:ok, _ref} = Shard.track(shard, self(), topic, "me", %{name: "me"})
    assert_join ^topic, "me", %{name: "me"}
    assert [{"me", %{name: "me", phx_ref: _}}] = list(shard, topic)

    {:ok, _ref} = Shard.track(shard, local_presence , topic, "me2", %{name: "me2"})
    assert_join ^topic, "me2", %{name: "me2"}
    assert [{"me", %{name: "me", phx_ref: _}},
            {"me2",%{name: "me2", phx_ref: _}}] =
           list(shard, topic)

    # remote joins
    assert replicas(shard) == %{}
    start_shard(@node1, name: tracker)
    track_presence(@node1, shard, remote_pres, topic, "node1", %{name: "s1"})
    assert_join ^topic, "node1", %{name: "s1"}
    assert_map %{@node1 => %Replica{status: :up}}, replicas(shard), 1
    assert [{"me", %{name: "me", phx_ref: _}},
            {"me2",%{name: "me2", phx_ref: _}},
            {"node1", %{name: "s1", phx_ref: _}}] =
           list(shard, topic)

    # local leaves
    Process.exit(local_presence, :kill)
    assert_leave ^topic, "me2", %{name: "me2"}
    assert [{"me", %{name: "me", phx_ref: _}},
            {"node1", %{name: "s1", phx_ref: _}}] =
           list(shard, topic)

    # remote leaves
    Process.exit(remote_pres, :kill)
    assert_leave ^topic, "node1", %{name: "s1"}
    assert [{"me", %{name: "me", phx_ref: _}}] = list(shard, topic)
  end

  test "detects nodedown and locally broadcasts leaves",
    %{shard: shard, topic: topic, tracker: tracker} do

    local_presence = spawn_pid()
    subscribe(topic)
    {node_pid, {:ok, node1_server}} = start_shard(@node1, name: tracker)
    assert list(shard, topic) == []

    {:ok, _ref} = Shard.track(shard, local_presence , topic, "local1", %{name: "l1"})
    assert_join ^topic, "local1", %{}

    track_presence(@node1, shard, spawn_pid(), topic, "node1", %{name: "s1"})
    assert_join ^topic, "node1", %{name: "s1"}
    assert %{@node1 => %Replica{status: :up}} = replicas(shard)
    assert [{"local1", _}, {"node1", _}] = list(shard, topic)

    # nodedown
    Process.unlink(node_pid)
    Process.exit(node1_server, :kill)
    assert_leave ^topic, "node1", %{name: "s1"}
    assert %{@node1 => %Replica{status: :down}} = replicas(shard)
    assert [{"local1", _}] = list(shard, topic)
  end

  test "untrack with no tracked topic is a noop",
    %{shard: shard, topic: topic} do
    assert Shard.untrack(shard, self(), topic, "foo") == :ok
  end

  test "untrack with topic",
    %{shard: shard, topic: topic} do

    Shard.track(shard, self(), topic, "user1", %{name: "user1"})
    Shard.track(shard, self(), "another:topic", "user2", %{name: "user2"})
    assert [{"user1", %{name: "user1"}}] = list(shard, topic)
    assert [{"user2", %{name: "user2"}}] = list(shard, "another:topic")
    assert Shard.untrack(shard, self(), topic, "user1") == :ok
    assert [] = list(shard, topic)
    assert [{"user2", %{name: "user2"}}] = list(shard, "another:topic")
    assert Process.whereis(shard) in Process.info(self())[:links]
    assert Shard.untrack(shard, self(), "another:topic", "user2") == :ok
    assert [] = list(shard, "another:topic")
    refute Process.whereis(shard) in Process.info(self())[:links]
  end

  test "untrack from all topics",
    %{shard: shard, topic: topic} do

    Shard.track(shard, self(), topic, "user1", %{name: "user1"})
    Shard.track(shard, self(), "another:topic", "user2", %{name: "user2"})
    assert [{"user1", %{name: "user1"}}] = list(shard, topic)
    assert [{"user2", %{name: "user2"}}] = list(shard, "another:topic")
    assert Process.whereis(shard) in Process.info(self())[:links]
    assert Shard.untrack(shard, self()) == :ok
    assert [] = list(shard, topic)
    assert [] = list(shard, "another:topic")
    refute Process.whereis(shard) in Process.info(self())[:links]
  end

  test "updating presence sends join/leave and phx_ref_prev",
    %{shard: shard, topic: topic} do

    subscribe(topic)
    {:ok, _ref} = Shard.track(shard, self(), topic, "u1", %{name: "u1"})
    assert [{"u1", %{name: "u1", phx_ref: ref}}] = list(shard, topic)
    {:ok, _ref} = Shard.update(shard, self(), topic, "u1", %{name: "u1-updated"})
    assert_leave ^topic, "u1", %{name: "u1", phx_ref: ^ref}
    assert_join ^topic, "u1", %{name: "u1-updated", phx_ref_prev: ^ref}
  end

  test "updating presence sends join/leave and phx_ref_prev with profer diffs if function for update used",
    %{shard: shard, topic: topic} do

    subscribe(topic)
    {:ok, _ref} = Shard.track(shard, self(), topic, "u1", %{browser: "Chrome", status: "online"})
    assert [{"u1", %{browser: "Chrome", status: "online", phx_ref: ref}}] = list(shard, topic)
    {:ok, _ref} = Shard.update(shard, self(), topic, "u1", fn meta -> Map.put(meta, :status, "away") end)
    assert_leave ^topic, "u1", %{browser: "Chrome", status: "online", phx_ref: ^ref}
    assert_join ^topic, "u1", %{browser: "Chrome", status: "away", phx_ref_prev: ^ref}
  end

  test "updating with no prior presence", %{shard: shard, topic: topic} do
    assert {:error, :nopresence} = Shard.update(shard, self(), topic, "u1", %{})
  end

  test "duplicate tracking", %{shard: shard, topic: topic} do
    pid = self()
    assert {:ok, _ref} = Shard.track(shard, pid, topic, "u1", %{})
    assert {:error, {:already_tracked, ^pid, ^topic, "u1"}} =
           Shard.track(shard, pid, topic, "u1", %{})
    assert {:ok, _ref} = Shard.track(shard, pid, "another:topic", "u1", %{})
    assert {:ok, _ref} = Shard.track(shard, pid, topic, "anotherkey", %{})

    assert :ok = Shard.untrack(shard, pid, topic, "u1")
    assert :ok = Shard.untrack(shard, pid, "another:topic", "u1")
    assert :ok = Shard.untrack(shard, pid, topic, "anotherkey")
  end

  test "graceful exits with permdown",
    %{shard: shard, topic: topic, tracker: tracker} do
    subscribe(topic)
    {_node_pid, {:ok, _node1_server}} = start_shard(@node1, name: tracker)
    track_presence(@node1, shard, spawn_pid(), topic, "node1", %{name: "s1"})
    assert_join ^topic, "node1", %{name: "s1"}
    assert %{@node1 => %Replica{status: :up}} = replicas(shard)
    assert [{"node1", _}] = list(shard, topic)

    # graceful permdown
    {_, :ok} = graceful_permdown(@node1, shard)
    assert_leave ^topic, "node1", %{name: "s1"}
    assert [] = list(shard, topic)
    assert replicas(shard) == %{}
  end

  # By default permdown period is 1.5 seconds in the tests. This however is
  # not enough to test this case.
  @tag tracker_opts: [permdown_period: 2000]
  test "rolling node update", %{topic: topic, shard: shard_name, tracker_opts: tracker_opts} do
    permdown_period = Keyword.fetch!(tracker_opts, :permdown_period)

    # Ensure 2 online shards - primary and node1
    spy_on_server(@primary, self(), shard_name)
    spy_on_server(@node1, self(), shard_name)
    {node1_node, {:ok, node1_shared}} = start_shard(@node1, tracker_opts)

    assert_receive {{:replica_up, @primary}, @node1}, @timeout
    assert_receive {{:replica_up, @node1}, @primary}, @timeout

    # Add one user to primary to ensure transfers are requested from new nodes
    track_presence(@primary, shard_name, spawn_pid(), topic, "primary", %{})

    assert_heartbeat(to: @primary, from: @node1)
    assert_heartbeat(to: @node1, from: @primary)

    # Remove node 1 (starts permdown grace on primary)
    Process.unlink(node1_node)
    Process.exit(node1_shared, :kill)
    assert_receive {{:replica_down, @node1}, @primary}, @timeout

    # Start node 2 (has no knowledge of node1)
    spy_on_server(@node2, self(), shard_name)
    {_node2_node, {:ok, _node2_shard}} = start_shard(@node2, tracker_opts)

    assert_receive {{:replica_up, @node2}, @primary}, @timeout
    assert_receive {{:replica_up, @primary}, @node2}, @timeout

    # Sends transfer request once
    assert_transfer_req(from: @node2, to: @primary)

    # Does not send more transfer requests
    refute_transfer_req(from: @node2, to: @primary)

    # Wait until primary is permanently down
    assert_receive {{:replica_permdown, @node1}, @primary}, permdown_period * 2
  end

  ## Helpers

  def spawn_pid, do: spawn(fn -> :timer.sleep(:infinity) end)

  def replicas(server), do: GenServer.call(server, :replicas)

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

  defp list(shard, topic) do
    Enum.sort(Shard.list(shard, topic))
  end
end
