defmodule Phoenix.Tracker.ShardRaceTest do
  @moduledoc """
  End-to-end reproduction of the CRDT race in `Phoenix.Tracker.State.merge/3`
  that corrupts presence state and ultimately crashes a shard with a
  `{:badmatch, N}` error (issue phoenixframework/phoenix_pubsub#148).

  ## Choreography (the #148 scenario)

    * primary = "node A": owns `alice`, drives the updates.
    * @node1  = "node B": receives A's initial state, then is partitioned off
      (`drop_gossips`) so it never learns of A's later updates. Its copy of
      `alice` is frozen at the first meta.
    * @node2  = "node C": comes up fresh, first learns A's *current* state via
      real gossip/delta replication, then receives a full-state
      `transfer_ack` extracted from the *stale* B.

  On buggy `State.merge/3`, C admits B's stale tag for `alice` even though it
  already holds a strictly-newer same-replica tag (the newer dots were
  compacted into the cloud), so C's `alice` meta is downgraded and a duplicate
  row is appended to the `pids` duplicate_bag. A later local leave then crashes
  the shard.

  ## Determinism note

  Real shard-to-shard `transfer_req`/`transfer_ack` target selection is not
  fully controllable from a test (the requesting node may pick any dominant
  replica, and timing decides ordering). To keep this test deterministic we
  drive the two *setup* phases with real replication (so the bug's
  preconditions are built by the real system), then inject the single decisive
  message -- a `transfer_ack` built from node B's genuinely-stale presence
  state -- directly into node C's shard. This is the exact message the shard
  would receive in production; only its arrival is made deterministic.

  All remote work is done via `:rpc.call/4` against library functions
  (`GenServer`, `State`, `Process`, `:erlang`) so that no closure from this
  test module needs to be loaded on the peer nodes.
  """
  use Phoenix.PubSub.NodeCase
  alias Phoenix.Tracker.{Shard, State, Replica}

  @node1 :"node1@127.0.0.1"
  @node2 :"node2@127.0.0.1"
  @moduletag :capture_log

  setup config do
    tracker = config.test
    tracker_opts = [name: tracker]
    {:ok, shard_pid} = start_shard(tracker_opts)

    {:ok,
     topic: to_string(tracker),
     shard: shard_name(tracker),
     shard_pid: shard_pid,
     tracker: tracker,
     tracker_opts: tracker_opts}
  end

  test "stale full-state transfer_ack from a partitioned node does not corrupt or crash a fresh node (issue #148)",
       %{shard: shard, topic: topic, tracker: tracker} do
    alice = spawn_pid()

    # --- Phase 1: A (primary) and B (@node1) connect; alice joins A; replicate.
    {_n1, {:ok, node1_shard}} = start_shard(@node1, name: tracker)
    assert %{@node1 => %Replica{status: :up}} = wait_for_replica(shard, @node1)

    {:ok, _ref} = Shard.track(shard, alice, topic, "alice", %{v: "initial"})
    # B observes the initial join via real replication.
    assert eventually(fn -> remote_meta(@node1, node1_shard, topic, "alice") == "initial" end),
           "node1 (B) never received alice's initial join"

    # --- Phase 2: partition B so it misses every later update from A.
    :ok = :rpc.call(@node1, GenServer, :call, [shard, :unsubscribe])

    # --- Phase 3: A updates alice twice; B stays frozen at "initial".
    {:ok, _ref} = Shard.update(shard, alice, topic, "alice", %{v: "update1"})
    {:ok, _ref} = Shard.update(shard, alice, topic, "alice", %{v: "second"})
    assert [{"alice", %{v: "second"}}] = list(shard, topic)

    # --- Phase 4: C (@node2) comes up. Rather than let it sync A's *full*
    # history (which would compact cleanly and hide the bug), we reproduce the
    # #148 timing: C first receives only A's incremental delta for the latest
    # "second" join -- exactly the heartbeat delta a node that joined mid-stream
    # would see. That delta's range starts above the earlier dots, so on C the
    # older dots for alice are never in the context: the live "second" dot lands
    # in the cloud with a *gap* at the compacted-away dots 1 (initial) and
    # 2 (the update1 leave).
    #
    # We isolate C from real gossip first so its knowledge is only what we
    # inject, keeping the scenario deterministic. Suspend A's and B's shards
    # while C starts and unsubscribes, so neither can slip a heartbeat into
    # the window between C's start and its unsubscribe (under full-suite load
    # that heartbeat catches C's context up and erases the compaction gap the
    # scenario depends on).
    :ok = :sys.suspend(shard)
    :ok = :rpc.call(@node1, :sys, :suspend, [node1_shard])

    {_n2, {:ok, node2_shard}} = start_shard(@node2, name: tracker)
    # Isolate C from real gossip as early as possible so it does NOT receive
    # A's full CRDT (which would compact cleanly and hide the bug); its only
    # knowledge of alice will be the incremental delta we inject below.
    :ok = :rpc.call(@node2, GenServer, :call, [node2_shard, :unsubscribe])

    :ok = :sys.resume(shard)
    :ok = :rpc.call(@node1, :sys, :resume, [node1_shard])

    # Read A's presences (local shard, real ETS) and the current tag for alice.
    a_presences = GenServer.call(shard, {:list, topic})
    a_ref = a_presences.replica

    [{{^topic, ^alice, "alice"}, %{v: "second"} = second_meta, alice_tag}] =
      :ets.lookup(a_presences.values, {topic, alice, "alice"})

    {^a_ref, alice_clock} = alice_tag

    # C's initial context (fresh: knows A at clock 0).
    node2_presences0 = :rpc.call(@node2, GenServer, :call, [node2_shard, {:list, topic}])
    node2_ref = node2_presences0.replica

    # Build A's incremental delta carrying ONLY the "second" join, with a range
    # that starts above the gap (start clock = alice_clock - 1). Delivered as a
    # heartbeat, this leaves a gap in C's context at the earlier dots.
    a_delta = %State{
      replica: a_ref,
      mode: :delta,
      values: %{alice_tag => {alice, topic, "alice", second_meta}},
      clouds: %{a_ref => MapSet.new([alice_tag])},
      range: {%{a_ref => alice_clock - 1}, %{a_ref => alice_clock}}
    }

    hb = {:pub, :heartbeat, a_ref, a_delta, {a_ref, %{a_ref => alice_clock}}}
    :rpc.call(@node2, :erlang, :send, [node2_shard, hb])
    Process.sleep(2 * @heartbeat)

    # C now sees alice = "second" but with a compaction gap in its context.
    assert remote_meta(@node2, node2_shard, topic, "alice") == "second",
           "node2 (C) did not observe alice = \"second\" from A's incremental delta"

    node2_presences = :rpc.call(@node2, GenServer, :call, [node2_shard, {:list, topic}])
    node2_ctx = node2_presences.context

    # Precondition for the bug: C's context for A must be behind the live
    # "second" dot, with that dot parked in the cloud (the compaction gap). If C
    # had received A's full CRDT this would not hold and the test would be
    # exercising the wrong path.
    assert Map.get(node2_ctx, a_ref, 0) < alice_clock,
           "node2 (C) context caught up to A (no compaction gap) -- got #{inspect(node2_ctx)}; " <>
             "C likely received A's full CRDT via real gossip. This is a test-setup race."

    assert MapSet.member?(Map.get(node2_presences.clouds, a_ref, MapSet.new()), alice_tag),
           "expected alice's live dot to be parked in C's cloud (the compaction gap)"

    # Confirm B is still frozen at "initial" (the stale source we will use).
    assert remote_meta(@node1, node1_shard, topic, "alice") == "initial"

    # --- Phase 5: build a full-state transfer_ack from the STALE B and deliver
    # it to C. This is exactly what C's shard would receive if it requested a
    # transfer from B. We extract B's presences for C's ref/context on B (so B's
    # local ETS is used), then inject on C.
    node1_presences = :rpc.call(@node1, GenServer, :call, [node1_shard, {:list, topic}])
    node1_ref = node1_presences.replica

    stale_extract =
      :rpc.call(@node1, State, :extract, [node1_presences, node2_ref, node2_ctx])

    # Monitor C's shard before delivering the message (distributed monitor).
    mref = Process.monitor(node2_shard)

    # Inject the stale transfer_ack into C's shard exactly as the network would.
    ack = {:pub, :transfer_ack, make_ref(), node1_ref, stale_extract}
    :rpc.call(@node2, :erlang, :send, [node2_shard, ack])

    # Give C a few heartbeats to process the injected message.
    Process.sleep(3 * @heartbeat)

    # --- Assertion (a): alice's raw CRDT row on C must keep the newer meta and
    # tag. We assert on the values table directly because A is legitimately
    # tempdown on C by now (C is cut off from gossip, so A goes silent past
    # max_silent_periods), which hides alice from the online list without
    # touching the CRDT row -- the row itself is what the stale ack corrupts.
    node2_presences_after = :rpc.call(@node2, GenServer, :call, [node2_shard, {:list, topic}])

    alice_row =
      :rpc.call(@node2, :ets, :lookup, [
        node2_presences_after.values,
        {topic, alice, "alice"}
      ])

    assert match?([{{^topic, ^alice, "alice"}, %{v: "second"}, ^alice_tag}], alice_row),
           "stale transfer_ack corrupted alice's CRDT row on node2 (C): #{inspect(alice_row)}"

    # --- Assertion (b): exactly one presence row for alice on C (no duplicates).
    assert remote_pid_row_count(@node2, node2_shard, alice) == 1,
           "stale transfer_ack appended a duplicate pid row on node2 (C)"

    # --- End-to-end view: revive A on C (empty heartbeat marks the replica back
    # up) and confirm alice is online with the latest meta. Re-send on each poll
    # so A cannot flap back to tempdown between checks.
    revive = {:pub, :heartbeat, a_ref, :empty, {a_ref, %{a_ref => alice_clock}}}

    assert eventually(fn ->
             :rpc.call(@node2, :erlang, :send, [node2_shard, revive])
             remote_meta(@node2, node2_shard, topic, "alice") == "second"
           end),
           "alice not online with meta \"second\" on node2 (C) after reviving replica A"

    # --- Assertion (c): a subsequent local leave on C must not crash the shard.
    # Kill alice's pid so C runs its local remove path (the crash site), and
    # untrack on the origin so a leave propagates through the cluster too.
    :ok = Shard.untrack(shard, alice, topic, "alice")
    Process.exit(alice, :kill)
    Process.sleep(3 * @heartbeat)

    refute_receive {:DOWN, ^mref, :process, ^node2_shard, {%MatchError{}, _}}, @timeout

    assert :rpc.call(@node2, Process, :alive?, [node2_shard]),
           "node2 (C) shard crashed after leave (the {:badmatch, N} shard crash)"
  end

  ## Helpers

  # Reads a remote shard's list for the topic and returns the meta value (the
  # :v field) for the given key, or nil. Shard.list/2 runs the ETS query on the
  # owning node, so this is safe across nodes.
  defp remote_meta(node, shard_pid, topic, key) do
    case :rpc.call(node, Shard, :list, [shard_pid, topic]) do
      list when is_list(list) ->
        Enum.find_value(list, fn
          {^key, %{v: v}} -> v
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  # Counts duplicate rows for a pid in the remote shard's pids duplicate_bag.
  # Both the struct fetch and the :ets.lookup run on the owning node, so the
  # table id is valid.
  defp remote_pid_row_count(node, shard_pid, pid) do
    presences = :rpc.call(node, GenServer, :call, [shard_pid, {:list, "_"}])
    :rpc.call(node, :ets, :lookup, [presences.pids, pid]) |> length()
  end

  defp wait_for_replica(shard, node) do
    Enum.reduce_while(1..50, nil, fn _, _ ->
      case replicas(shard) do
        %{^node => %Replica{status: :up}} = r ->
          {:halt, r}

        _ ->
          Process.sleep(@heartbeat)
          {:cont, nil}
      end
    end)
  end

  defp eventually(fun, tries \\ 30) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(@heartbeat)
        {:cont, false}
      end
    end)
  end

  defp spawn_pid, do: spawn(fn -> :timer.sleep(:infinity) end)

  defp replicas(server), do: GenServer.call(server, :replicas)

  defp list(shard, topic), do: Enum.sort(Shard.list(shard, topic))
end
