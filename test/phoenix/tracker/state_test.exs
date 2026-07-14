defmodule Phoenix.Tracker.StateTest do
  use ExUnit.Case, async: true
  alias Phoenix.Tracker.{State}

  def sorted_clouds(clouds) do
    clouds
    |> Enum.flat_map(fn {_name, cloud} -> Enum.to_list(cloud) end)
    |> Enum.sort()
  end

  defp new(node, config) do
    State.new({node, 1}, :"#{node} #{config.test}")
  end

  defp new_pid() do
    spawn(fn -> :ok end)
  end

  defp keys(elements) do
    elements
    |> Enum.map(fn {{_, _, key}, _, _} -> key end)
    |> Enum.sort()
  end

  defp tab2list(tab), do: tab |> :ets.tab2list() |> Enum.sort()

  test "that this is set up correctly", config do
    a = new(:a, config)
    assert {_a, map} = State.extract(a, a.replica, a.context)
    assert map == %{}
  end

  test "user added online is online", config do
    a = new(:a, config)
    john = new_pid()
    a = State.join(a, john, "lobby", :john)
    assert [{:john, _meta}] = State.get_by_topic(a, "lobby")
    a = State.leave(a, john, "lobby", :john)
    assert [] = State.get_by_topic(a, "lobby")
  end

  test "users from other servers merge", config do
    a = new(:a, config)
    b = new(:b, config)
    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid()
    bob = new_pid()
    carol = new_pid()

    assert [] = tab2list(a.pids)
    a = State.join(a, alice, "lobby", :alice)
    assert [{_, "lobby", :alice}] = tab2list(a.pids)
    b = State.join(b, bob, "lobby", :bob)

    # Merging emits a bob join event
    assert {a, [{{_, _, :bob}, _, _}], []} =
             State.merge(a, State.extract(b, a.replica, a.context))

    assert [:alice, :bob] = keys(State.online_list(a))

    # Merging twice doesn't dupe events
    pids_before = tab2list(a.pids)
    assert {newa, [], []} = State.merge(a, State.extract(b, a.replica, a.context))
    assert newa == a
    assert pids_before == tab2list(newa.pids)

    assert {b, [{{_, _, :alice}, _, _}], []} =
             State.merge(b, State.extract(a, b.replica, b.context))

    assert {^b, [], []} = State.merge(b, State.extract(a, b.replica, b.context))

    # observe remove
    assert [{_, "lobby", :alice}, {_, "lobby", :bob}] = tab2list(a.pids)
    a = State.leave(a, alice, "lobby", :alice)
    assert [{_, "lobby", :bob}] = tab2list(a.pids)
    b_pids_before = tab2list(b.pids)
    assert [{_, "lobby", :alice}, {_, "lobby", :bob}] = b_pids_before

    assert {b, [], [{{_, _, :alice}, _, _}]} =
             State.merge(b, State.extract(a, b.replica, b.context))

    assert [{_, "lobby", :alice}] = b_pids_before -- tab2list(b.pids)

    assert [:bob] = keys(State.online_list(b))
    assert {^b, [], []} = State.merge(b, State.extract(a, b.replica, b.context))

    b = State.join(b, carol, "lobby", :carol)

    assert [:bob, :carol] = keys(State.online_list(b))

    assert {a, [{{_, _, :carol}, _, _}], []} =
             State.merge(a, State.extract(b, a.replica, a.context))

    assert {^a, [], []} = State.merge(a, State.extract(b, a.replica, a.context))

    assert State.online_list(b) |> Enum.sort() == State.online_list(a) |> Enum.sort()

    # update
    b = State.leave_join(b, carol, "lobby", :carol, %{updated: true})
    pids_before = tab2list(a.pids)

    assert {a, [{{_, _, :carol}, %{updated: true}, _}], [{{_, _, :carol}, _, _}]} =
             State.merge(a, State.extract(b, a.replica, a.context))

    assert {^a, [], []} = State.merge(a, State.extract(b, a.replica, a.context))

    assert pids_before == tab2list(a.pids)
  end

  test "basic netsplit", config do
    a = new(:a, config)
    b = new(:b, config)
    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid()
    bob = new_pid()
    carol = new_pid()
    david = new_pid()

    a = State.join(a, alice, "lobby", :alice)
    b = State.join(b, bob, "lobby", :bob)

    {a, [{{_, _, :bob}, _, _}], _} = State.merge(a, State.extract(b, a.replica, a.context))

    assert [:alice, :bob] = a |> State.online_list() |> keys()

    a = State.join(a, carol, "lobby", :carol)
    a = State.leave(a, alice, "lobby", :alice)
    a = State.join(a, david, "lobby", :david)

    assert {a, [], [{{_, _, :bob}, _, _}]} = State.replica_down(a, {:b, 1})

    assert [:carol, :david] = keys(State.online_list(a))

    assert {a, [], []} = State.merge(a, State.extract(b, a.replica, a.context))
    assert [:carol, :david] = keys(State.online_list(a))

    assert {a, [{{_, _, :bob}, _, _}], []} = State.replica_up(a, {:b, 1})

    assert [:bob, :carol, :david] = keys(State.online_list(a))
  end

  test "joins are observed via other node", config do
    [a, b, c] = given_connected_cluster([:a, :b, :c], config)
    alice = new_pid()
    bob = new_pid()
    a = State.join(a, alice, "lobby", :alice)
    # the below join is just so that node c has some context from node a
    {c, [{{_, _, :alice}, _, _}], []} =
      State.merge(c, State.extract(a, c.replica, c.context))

    # netsplit between a and c
    {a, [], []} = State.replica_down(a, {:c, 1})
    {c, [], [{{_, _, :alice}, _, _}]} = State.replica_down(c, {:a, 1})

    a = State.join(a, bob, "lobby", :bob)

    {b, [{{_, _, :bob}, _, _}, {{_, _, :alice}, _, _}], []} =
      State.merge(b, State.extract(a, b.replica, b.context))

    assert {_, [{{_, _, :bob}, _, _}], []} =
             State.merge(c, State.extract(b, c.replica, c.context))
  end

  test "removes are observed via other node", config do
    [a, b, c] = given_connected_cluster([:a, :b, :c], config)
    alice = new_pid()
    bob = new_pid()
    a = State.join(a, alice, "lobby", :alice)

    {c, [{{_, _, :alice}, _, _}], []} =
      State.merge(c, State.extract(a, c.replica, c.context))

    # netsplit between a and c
    {a, [], []} = State.replica_down(a, {:c, 1})
    {c, [], [{{_, _, :alice}, _, _}]} = State.replica_down(c, {:a, 1})

    a = State.join(a, bob, "lobby", :bob)

    {b, [{{_, _, :bob}, _, _}, {{_, _, :alice}, _, _}], []} =
      State.merge(b, State.extract(a, b.replica, b.context))

    {c, [{{_, _, :bob}, _, _}], []} =
      State.merge(c, State.extract(b, c.replica, c.context))

    a = State.leave(a, bob, "lobby", :bob)

    {b, [], [{{_, _, :bob}, _, _}]} =
      State.merge(b, State.extract(a, b.replica, b.context))

    assert {_, [], [{{_, _, :bob}, _, _}]} =
             State.merge(c, State.extract(b, c.replica, c.context))
  end

  test "get_by_pid", config do
    pid = self()
    state = new(:node1, config)

    assert State.get_by_pid(state, pid) == []
    state = State.join(state, pid, "topic", "key1", %{})

    assert [{{"topic", ^pid, "key1"}, %{}, {{:node1, 1}, 1}}] =
             State.get_by_pid(state, pid)

    assert {{"topic", ^pid, "key1"}, %{}, {{:node1, 1}, 1}} =
             State.get_by_pid(state, pid, "topic", "key1")

    assert State.get_by_pid(state, pid, "notopic", "key1") == nil
    assert State.get_by_pid(state, pid, "notopic", "nokey") == nil
  end

  test "get_by_key", config do
    pid = self()
    pid2 = spawn(fn -> Process.sleep(:infinity) end)
    state = new(:node1, config)

    assert State.get_by_key(state, "topic", "key1") == []
    state = State.join(state, pid, "topic", "key1", %{device: :browser})
    state = State.join(state, pid2, "topic", "key1", %{device: :ios})
    state = State.join(state, pid2, "topic", "key2", %{device: :ios})

    assert [{^pid, %{device: :browser}}, {_pid2, %{device: :ios}}] =
             State.get_by_key(state, "topic", "key1")

    assert State.get_by_key(state, "another_topic", "key1") == []
    assert State.get_by_key(state, "topic", "another_key") == []
  end

  test "get_by_topic", config do
    pid = self()
    state = new(:node1, config)
    state2 = new(:node2, config)
    state3 = new(:node3, config)
    {state, _, _} = State.replica_up(state, {:node2, 1})
    {state, _, _} = State.replica_up(state, {:node3, 1})

    {state2, _, _} = State.replica_up(state2, {:node1, 1})
    {state2, _, _} = State.replica_up(state2, {:node3, 1})

    {state3, _, _} = State.replica_up(state3, {:node1, 1})
    {state3, _, _} = State.replica_up(state3, {:node2, 1})

    assert state.context ==
             %{{:node2, 1} => 0, {:node3, 1} => 0, {:node1, 1} => 0}

    assert state2.context ==
             %{{:node1, 1} => 0, {:node3, 1} => 0, {:node2, 1} => 0}

    assert state3.context ==
             %{{:node1, 1} => 0, {:node2, 1} => 0, {:node3, 1} => 0}

    user2 = new_pid()
    user3 = new_pid()

    assert [] = State.get_by_topic(state, "topic")
    state = State.join(state, pid, "topic", "key1", %{})
    state = State.join(state, pid, "topic", "key2", %{})
    state2 = State.join(state2, user2, "topic", "user2", %{})
    state3 = State.join(state3, user3, "topic", "user3", %{})

    # all replicas online
    assert [{"key1", %{}}, {"key2", %{}}] =
             State.get_by_topic(state, "topic")

    {state, _, _} = State.merge(state, State.extract(state2, state.replica, state.context))
    {state, _, _} = State.merge(state, State.extract(state3, state.replica, state.context))

    assert [{"key1", %{}}, {"key2", %{}}, {"user2", %{}}, {"user3", %{}}] =
             State.get_by_topic(state, "topic")

    # one replica offline
    {state, _, _} = State.replica_down(state, state2.replica)

    assert [{"key1", %{}}, {"key2", %{}}, {"user3", %{}}] =
             State.get_by_topic(state, "topic")

    # two replicas offline
    {state, _, _} = State.replica_down(state, state3.replica)
    assert [{"key1", %{}}, {"key2", %{}}] = State.get_by_topic(state, "topic")

    assert [] = State.get_by_topic(state, "another:topic")
  end

  test "remove_down_replicas", config do
    state1 = new(:node1, config)
    state2 = new(:node2, config)
    {state1, _, _} = State.replica_up(state1, state2.replica)
    {state2, _, _} = State.replica_up(state2, state1.replica)

    alice = new_pid()
    bob = new_pid()

    state1 = State.join(state1, alice, "lobby", :alice)
    state2 = State.join(state2, bob, "lobby", :bob)
    {state2, _, _} = State.merge(state2, State.extract(state1, state2.replica, state2.context))
    assert keys(State.online_list(state2)) == [:alice, :bob]

    {state2, _, _} = State.replica_down(state2, {:node1, 1})
    assert [{^alice, "lobby", :alice}, {^bob, "lobby", :bob}] = tab2list(state2.pids)

    state2 = State.remove_down_replicas(state2, {:node1, 1})
    assert [{^bob, "lobby", :bob}] = tab2list(state2.pids)
    {state2, _, _} = State.replica_up(state2, {:node1, 1})
    assert keys(State.online_list(state2)) == [:bob]
  end

  test "basic deltas", config do
    a = new(:a, config)
    b = new(:b, config)

    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid()
    bob = new_pid()

    a = State.join(a, alice, "lobby", :alice)
    b = State.join(b, bob, "lobby", :bob)

    assert {b, [{{_, _, :alice}, _, _}], []} = State.merge(b, a.delta)
    assert {{:b, 1}, %{{:a, 1} => 1, {:b, 1} => 1}} = State.clocks(b)

    a = State.reset_delta(a)
    a = State.leave(a, alice, "lobby", :alice)

    assert {b, [], [{{_, _, :alice}, _, _}]} = State.merge(b, a.delta)
    assert {{:b, 1}, %{{:a, 1} => 2, {:b, 1} => 1}} = State.clocks(b)

    a = State.join(a, alice, "lobby", :alice)
    assert {b, [{{_, _, :alice}, _, _}], []} = State.merge(b, a.delta)
    assert {{:b, 1}, %{{:a, 1} => 3, {:b, 1} => 1}} = State.clocks(b)
    assert Enum.all?(Enum.map(b.clouds, fn {_, cloud} -> Enum.empty?(cloud) end))
  end

  test "deltas are not merged for non-contiguous ranges", config do
    s1 = new(:s1, config)
    s2 = State.join(s1, new_pid(), "lobby", "user1", %{})
    s3 = State.join(s2, new_pid(), "lobby", "user2", %{})
    s4 = State.join(State.reset_delta(s3), new_pid(), "lobby", "user3", %{})

    assert State.merge_deltas(s2.delta, s4.delta) == {:error, :not_contiguous}
    assert State.merge_deltas(s4.delta, s2.delta) == {:error, :not_contiguous}
  end

  test "extracted state context contains only replicas known to remote replica",
       config do
    s1 = new(:s1, config)
    s2 = new(:s2, config)
    s3 = new(:s3, config)
    {s1, _, _} = State.replica_up(s1, s2.replica)
    {s2, _, _} = State.replica_up(s2, s1.replica)
    {s2, _, _} = State.replica_up(s2, s3.replica)
    s1 = State.join(s1, new_pid(), "lobby", "user1", %{})
    s2 = State.join(s2, new_pid(), "lobby", "user2", %{})
    s3 = State.join(s3, new_pid(), "lobby", "user3", %{})
    {s1, _, _} = State.merge(s1, s2.delta)
    {s2, _, _} = State.merge(s2, s1.delta)
    {s2, _, _} = State.merge(s2, s3.delta)

    {extracted, _} = State.extract(s2, s1.replica, s1.context)

    assert extracted.context == %{{:s1, 1} => 1, {:s2, 1} => 1}
  end

  test "merging deltas", config do
    s1 = new(:s1, config)
    s2 = new(:s2, config)
    user1 = new_pid()
    user2 = new_pid()

    s1 = State.join(s1, user1, "lobby", "user1", %{})
    s1 = State.join(s1, user1, "private", "user1", %{})
    s2 = State.join(s2, user2, "lobby", "user2", %{})
    s2 = State.join(s2, user2, "private", "user2", %{})

    {:ok, delta1} = State.merge_deltas(s1.delta, s2.delta)

    assert delta1.values == %{
             {{:s1, 1}, 1} => {user1, "lobby", "user1", %{}},
             {{:s1, 1}, 2} => {user1, "private", "user1", %{}},
             {{:s2, 1}, 1} => {user2, "lobby", "user2", %{}},
             {{:s2, 1}, 2} => {user2, "private", "user2", %{}}
           }

    assert sorted_clouds(delta1.clouds) ==
             [{{:s1, 1}, 1}, {{:s1, 1}, 2}, {{:s2, 1}, 1}, {{:s2, 1}, 2}]
  end

  test "merging deltas with removes", config do
    s1 = new(:s1, config)
    s2 = new(:s2, config)
    user1 = new_pid()
    {s1, _, _} = State.replica_up(s1, s2.replica)
    {s2, _, _} = State.replica_up(s2, s1.replica)

    # concurrent add wins
    s1 = State.join(s1, user1, "lobby", "user1", %{})
    s1 = State.join(s1, user1, "private", "user1", %{})
    s2 = State.join(s2, user1, "lobby", "user1", %{})
    s2 = State.leave(s2, user1, "lobby", "user1")

    {:ok, delta1} = State.merge_deltas(s1.delta, s2.delta)
    s1 = %{s1 | delta: delta1}

    assert delta1.values == %{
             {{:s1, 1}, 1} => {user1, "lobby", "user1", %{}},
             {{:s1, 1}, 2} => {user1, "private", "user1", %{}}
           }

    assert sorted_clouds(delta1.clouds) ==
             [{{:s1, 1}, 1}, {{:s1, 1}, 2}, {{:s2, 1}, 1}, {{:s2, 1}, 2}]

    # merging duplicates maintains delta
    assert {:ok, ^delta1} = State.merge_deltas(delta1, s2.delta)

    {s2, _, _} = State.merge(s2, s1.delta)
    s2 = State.leave(s2, user1, "private", "user1")

    # observed remove
    {:ok, delta1} = State.merge_deltas(s1.delta, s2.delta)

    assert delta1.values == %{
             {{:s1, 1}, 1} => {user1, "lobby", "user1", %{}}
           }

    # maintains tombstone
    assert sorted_clouds(delta1.clouds) ==
             [{{:s1, 1}, 1}, {{:s1, 1}, 2}, {{:s2, 1}, 1}, {{:s2, 1}, 2}, {{:s2, 1}, 3}]
  end

  test "stale full-state transfer does not overwrite newer values from delta (issue #148)",
       config do
    # Reproduces phoenixframework/phoenix_pubsub#148.
    #
    # A and B are connected. alice joins A as "initial" and A's state is
    # replicated to B. alice then leaves+joins on A ("update1") but that delta
    # never reaches B, so B's copy of alice is stuck at "initial". A third
    # replica C comes up and first merges A's delta (learning alice="second"),
    # then merges a full-state transfer_ack extracted from the *stale* B.
    #
    # Because A's context for alice was compacted away on C (the local :a clock
    # sits at 0 with the live dots parked in the cloud), the stale tag
    # {{:a,1},1} is not recognised as already-observed, so merge/3 admits it:
    # the newer row is downgraded ("second" -> "initial") and a duplicate pid
    # row is appended.
    a = new(:a, config)
    b = new(:b, config)
    c = new(:c, config)

    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid()

    # alice joins A as "initial"; replicate the full state to B
    a = State.join(a, alice, "lobby", :alice, %{v: "initial"})

    {b, [{{_, _, :alice}, %{v: "initial"}, _}], []} =
      State.merge(b, State.extract(a, b.replica, b.context))

    a = State.reset_delta(a)

    # alice leave+joins on A ("update1"); this delta never reaches B
    a = State.leave_join(a, alice, "lobby", :alice, %{v: "update1"})
    a = State.reset_delta(a)

    # C comes up and everyone learns about everyone
    {a, _, _} = State.replica_up(a, c.replica)
    {c, _, _} = State.replica_up(c, a.replica)
    {c, _, _} = State.replica_up(c, b.replica)
    {b, _, _} = State.replica_up(b, c.replica)

    # alice leave+joins on A a final time ("second")
    a = State.leave_join(a, alice, "lobby", :alice, %{v: "second"})

    # C merges A's delta and correctly observes alice = "second"
    {c, [{{_, _, :alice}, %{v: "second"}, _}], []} = State.merge(c, a.delta)
    assert [{^alice, %{v: "second"}}] = State.get_by_key(c, "lobby", :alice)
    # a-context has been compacted to 0 with the live dots parked in the cloud
    assert %{{:a, 1} => 0} = c.context

    # C now merges a full-state transfer_ack from the *stale* B replica.
    {c, _joins, _leaves} = State.merge(c, State.extract(b, c.replica, c.context))

    # (a) alice's meta must NOT be downgraded back to "initial"
    assert [{^alice, %{v: "second"}}] = State.get_by_key(c, "lobby", :alice),
           "stale full-state transfer downgraded alice from \"second\" to a prior meta"

    # (b) no duplicate rows may accumulate in the pids duplicate_bag
    assert length(:ets.lookup(c.pids, alice)) == 1,
           "stale full-state transfer appended a duplicate pid row"

    # (c) after subsequently merging A's full extract, alice remains online
    {c, _joins, _leaves} = State.merge(c, State.extract(a, c.replica, c.context))

    assert [{^alice, %{v: "second"}}] = State.get_by_key(c, "lobby", :alice),
           "alice disappeared after merging A's full extract"
  end

  test "duplicate pid rows from stale transfers crash leave/2 with {:badmatch, N} (issue #148)",
       config do
    # Documents the production crash: repeated stale full-state transfers build
    # up N > 1 duplicate rows in the pids duplicate_bag for a single
    # {topic, pid, key}. A later local leave calls remove/4, whose
    # `1 = :ets.select_delete(pids, ...)` guard then raises
    # `{:badmatch, N}`, taking down the shard. Production Sentry shows
    # {:badmatch, 3}.
    a = new(:a, config)
    b = new(:b, config)
    c = new(:c, config)

    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid()

    a = State.join(a, alice, "lobby", :alice, %{v: "initial"})
    {b, _, _} = State.merge(b, State.extract(a, b.replica, b.context))
    a = State.reset_delta(a)

    a = State.leave_join(a, alice, "lobby", :alice, %{v: "update1"})
    a = State.reset_delta(a)

    {a, _, _} = State.replica_up(a, c.replica)
    {c, _, _} = State.replica_up(c, a.replica)
    {c, _, _} = State.replica_up(c, b.replica)
    {_b, _, _} = State.replica_up(b, c.replica)

    a = State.leave_join(a, alice, "lobby", :alice, %{v: "second"})
    {c, _, _} = State.merge(c, a.delta)

    # C's a-clock is 0 with the live dots {3,4,5} parked in the cloud, leaving
    # a gap at dots 1 and 2. Two *independent* stale full-state transfers (from
    # two replicas that never observed each other's dot) each fill a gap dot
    # and each appends an orphan duplicate pid row, without cancelling.
    stale = fn tag, meta ->
      {%Phoenix.Tracker.State{
         c
         | mode: :normal,
           context: %{{:a, 1} => 0, {:b, 1} => 0, {:c, 1} => 0},
           clouds: %{},
           # Safe to blank the tables here: merge/3 -> observe_removes reads
           # only the remote's context and clouds, never remote.values or
           # remote.pids. If that ever changes, this fabrication must too.
           values: nil,
           pids: nil,
           delta: :unset
       }, %{tag => {alice, "lobby", :alice, meta}}}
    end

    {c, _, _} = State.merge(c, stale.({{:a, 1}, 1}, %{v: "initial"}))
    {c, _, _} = State.merge(c, stale.({{:a, 1}, 2}, %{v: "gap"}))

    # After the fix, stale transfers must not accumulate duplicate pid rows:
    # alice must have exactly one row. On buggy main there are 3, which is what
    # drives the crash below.
    #
    # This assertion FAILS on buggy main (finds 3), documenting the corruption.
    assert length(:ets.lookup(c.pids, alice)) == 1,
           "stale full-state transfers accumulated duplicate pid rows for alice"

    # And the follow-on symptom: a subsequent local leave must not crash. On
    # buggy main, remove/4's `1 = :ets.select_delete(pids, ...)` guard sees 3
    # rows and raises a MatchError with term 3 -- the {:badmatch, 3} shard
    # crash seen in production Sentry (issue #148). We capture that here so it
    # is unmistakable which failure mode this reproduces.
    crash =
      try do
        State.leave(c, alice)
        nil
      rescue
        e in MatchError -> e
      end

    assert crash == nil,
           "State.leave/2 crashed after stale transfers: #{inspect(crash)} " <>
             "(the production {:badmatch, N} shard crash)"
  end

  defp given_connected_cluster(nodes, config) do
    states = Enum.map(nodes, fn n -> new(n, config) end)
    replicas = Enum.map(states, fn s -> s.replica end)

    Enum.map(states, fn s ->
      Enum.reduce(replicas, s, fn replica, acc ->
        case acc.replica == replica do
          true -> acc
          false -> State.replica_up(acc, replica) |> elem(0)
        end
      end)
    end)
  end
end
