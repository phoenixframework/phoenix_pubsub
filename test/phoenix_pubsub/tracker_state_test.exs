defmodule Phoenix.StateTest do
  use ExUnit.Case
  alias Phoenix.Tracker.{State}

  defp new(node) do
    State.new({node, 1})
  end

  defp new_pid() do
    spawn(fn -> :ok end)
  end

  defp keys(elements) do
    elements
    |> Enum.map(fn {_, {{key, _}, _}} -> key end)
    |> Enum.sort()
  end

  test "that this is set up correctly" do
    a = new(:a)
    assert {_a, map} = State.extract(a)
    assert map == %{}
  end

  test "user added online is online" do
    a = new(:a)
    john = new_pid()
    a = State.join(a, john, "lobby", :john)
    assert [{_, {{:john, _}, _}}] = State.get_by_topic(a, "lobby")
    a = State.leave(a, john, "lobby", :john)
    assert [] = State.get_by_topic(a, "lobby")
  end

  test "users from other servers merge" do
    a = new(:a)
    b = new(:b)
    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid
    bob = new_pid
    carol = new_pid

    a = State.join(a, alice, "lobby", :alice)
    b = State.join(b, bob, "lobby", :bob)

    # Merging emits a bob join event
    assert {a,[{_,{{:bob,_}, _}}],[]} = State.merge(a, State.extract(b))
    assert [:alice,:bob] = keys(State.online_list(a))

    # Merging twice doesn't dupe events
    assert {newa,[],[]} = State.merge(a, State.extract(b))
    assert newa == a

    assert {b,[{_,{{:alice,_}, _}}],[]} = State.merge(b, State.extract(a))
    assert {^b,[],[]} = State.merge(b, State.extract(a))
    a = State.leave(a, alice, "lobby", :alice)
    assert {b,[],[{_,{{:alice,_}, _}}]} = State.merge(b, State.extract(a))

    assert [:bob] = keys(State.online_list(b))
    assert {^b,[],[]} = State.merge(b, State.extract(a))

    b = State.join(b, carol, "lobby", :carol)

    assert [:bob, :carol] = keys(State.online_list(b))
    assert {a,[{_,{{:carol,_}, _}}],[]} = State.merge(a, State.extract(b))
    assert {^a,[],[]} = State.merge(a, State.extract(b))

    assert (State.online_list(b) |> Enum.sort) == (State.online_list(a) |> Enum.sort)
  end

  test "basic netsplit" do
    a = new(:a)
    b = new(:b)
    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid
    bob = new_pid
    carol = new_pid
    david = new_pid

    a = State.join(a, alice, "lobby", :alice)
    b = State.join(b, bob, "lobby", :bob)

    {a, [{_, {{:bob,_}, _}}], _} = State.merge(a, State.extract(b))

    assert [:alice, :bob] = a |> State.online_list() |> keys()

    a = State.join(a, carol, "lobby", :carol)
    a = State.leave(a, alice, "lobby", :alice)
    a = State.join(a, david, "lobby", :david)

    assert {a,[],[{_,{{:bob,_}, _}}]} = State.replica_down(a, {:b,1})

    assert [:carol, :david] = keys(State.online_list(a))

    assert {a,[],[]} = State.merge(a, State.extract(b))
    assert [:carol, :david] = keys(State.online_list(a))

    assert {a,[{_,{{:bob,_}, _}}],[]} = State.replica_up(a, {:b,1})

    assert [:bob, :carol, :david] = keys(State.online_list(a))
  end

  test "get_by_pid" do
    pid = self()
    state = new(:node1)

    assert [] = State.get_by_pid(state, pid)
    state = State.join(state, pid, "topic", "key1", %{})
    assert [{{^pid, "topic"}, {{"key1", %{}}, {{:node1, 1}, 1}}}] =
           State.get_by_pid(state, pid)

    assert {{^pid, "topic"}, {{"key1", %{}}, {{:node1, 1}, 1}}} =
           State.get_by_pid(state, pid, "topic", "key1")

    assert State.get_by_pid(state, pid, "notopic", "key1") == nil
    assert State.get_by_pid(state, pid, "notopic", "nokey") == nil
  end

  test "get_by_topic" do
    pid = self()
    state = new(:node1)

    assert [] = State.get_by_topic(state, "topic")
    state = State.join(state, pid, "topic", "key1", %{})
    state = State.join(state, pid, "topic", "key2", %{})
    assert [{{^pid, "topic"}, {{"key1", %{}}, {{:node1, 1}, 1}}},
            {{^pid, "topic"}, {{"key2", %{}}, {{:node1, 1}, 2}}}] =
           State.get_by_topic(state, "topic")

    assert [] = State.get_by_topic(state, "another:topic")
  end

  test "remove_down_nodes" do
    state1 = new(:node1)
    state2 = new(:node2)
    {state1, _, _} = State.replica_up(state1, state2.replica)
    {state2, _, _} = State.replica_up(state2, state1.replica)

    alice = new_pid
    bob = new_pid

    state1 = State.join(state1, alice, "lobby", :alice)
    state2 = State.join(state2, bob, "lobby", :bob)
    {state2, _, _} = State.merge(state2, State.extract(state1))
    assert keys(State.online_list(state2)) == [:alice, :bob]

    {state2, _, _} = State.replica_down(state2, {:node1, 1})
    state2 = State.remove_down_replicas(state2, {:node1, 1})
    {state2, _, _} = State.replica_up(state2, {:node1, 1})
    assert keys(State.online_list(state2)) == [:bob]
  end

  test "basic deltas" do
    a = new(:a)
    b = new(:b)

    alice = new_pid
    bob = new_pid

    a = State.join(a, alice, "lobby", :alice)
    b = State.join(b, bob, "lobby", :bob)

    assert {b, [{_, {{:alice, _}, _}}], []} = State.merge(b, a.delta)
    assert {{:b, 1}, %{{:a, 1} => 1, {:b, 1} => 1}} = State.clocks(b)

    a = State.reset_delta(a)
    a = State.leave(a, alice, "lobby", :alice)

    assert {b, [], [{_, {{:alice, _}, _}}]} = State.merge(b, a.delta)
    assert {{:b, 1}, %{{:a, 1} => 2, {:b, 1} => 1}} = State.clocks(b)

    a = State.join(a, alice, "lobby", :alice)
    assert {b, [{_, {{:alice, _}, _}}], []} = State.merge(b, a.delta)
    assert {{:b, 1}, %{{:a, 1} => 3, {:b, 1} => 1}} = State.clocks(b)
    assert Enum.empty?(b.cloud)
  end

  test "merging deltas" do
    s1 = new(:s1)
    s2 = new(:s2)
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
    assert Enum.sort(delta1.cloud) ==
      [{{:s1, 1}, 1}, {{:s1, 1}, 2}, {{:s2, 1}, 1}, {{:s2, 1}, 2}]
  end

  test "merging deltas with removes" do
    s1 = new(:s1)
    s2 = new(:s2)
    user1 = new_pid()

    # concurrent add wins
    s1 = State.join(s1, user1, "lobby", "user1", %{})
    s1 = State.join(s1, user1, "private", "user1", %{})
    s2 = State.join(s2, user1, "lobby", "user1", %{})
    s2 = State.leave(s2, user1, "lobby", "user1")

    {:ok, delta1} = State.merge_deltas(s1.delta, s2.delta)
    s1 = %State{s1 | delta: delta1}
    assert delta1.values == %{
      {{:s1, 1}, 1} => {user1, "lobby", "user1", %{}},
      {{:s1, 1}, 2} => {user1, "private", "user1", %{}},
    }
    assert Enum.sort(delta1.cloud) ==
      [{{:s1, 1}, 1}, {{:s1, 1}, 2}, {{:s2, 1}, 1}, {{:s2, 1}, 2}]

    # merging duplicates maintains delta
    assert {:ok, ^delta1} = State.merge_deltas(delta1, s2.delta)

    {s2, _, _} = State.merge(s2, s1.delta)
    s2 = State.leave(s2, user1, "private", "user1")

    # observed remove
    {:ok, delta1} = State.merge_deltas(s1.delta, s2.delta)
    assert delta1.values == %{
      {{:s1, 1}, 1} => {user1, "lobby", "user1", %{}},
    }
    # maintains tombstone
    assert Enum.sort(delta1.cloud) ==
      [{{:s1, 1}, 1}, {{:s1, 1}, 2}, {{:s2, 1}, 1}, {{:s2, 1}, 2}, {{:s2, 1}, 3}]
  end
end
