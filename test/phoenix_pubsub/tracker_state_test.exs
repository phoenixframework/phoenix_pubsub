defmodule Phoenix.StateTest do
  use ExUnit.Case

  alias Phoenix.Tracker.State, as: State

  # Partial netsplit multiple joins

  # New print-callback Presence
  defp newp(node) do
    State.new({node, 1})
  end

  defp new_conn() do
    make_ref()
  end

  defp keys(elements) do
    elements
    |> Enum.map(fn {_, {{key, _}, _}} -> key end)
    |> Enum.sort()
  end

  test "that this is set up correctly" do
    a = newp(:a)
    assert {_a, map} = State.extract(a)
    assert map == %{}
  end

  test "user added online is online" do
    a = newp(:a)
    john = new_conn()
    a = State.join(a, john, "lobby", :john)
    assert [{_, {{:john, _}, _}}] = State.get_by_topic(a, "lobby")
    a = State.leave(a, john, "lobby", :john)
    assert [] = State.get_by_topic(a, "lobby")
  end

  test "users from other servers merge" do
    a = newp(:a)
    b = newp(:b)
    {a, _, _} = State.node_up(a, b.replica)
    {b, _, _} = State.node_up(b, a.replica)

    alice = new_conn
    bob = new_conn
    carol = new_conn

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

  test "basic deltas" do
    a = newp(:a)
    b = newp(:b)

    alice = new_conn
    bob = new_conn

    a = State.join(a, alice, "lobby", :alice)
    b = State.join(b, bob, "lobby", :bob)

    assert {b, [{_, {{:alice, _}, _}}], []} = State.merge(b, State.extract_delta(a))
    assert {{:b, 1}, %{{:a, 1} => 1, {:b, 1} => 1}} = State.clocks(b)

    a = State.reset_delta(a)
    a = State.leave(a, alice, "lobby", :alice)

    assert {b, [], [{_, {{:alice, _}, _}}]} = State.merge(b, State.extract_delta(a))
    assert {{:b, 1}, %{{:a, 1} => 2, {:b, 1} => 1}} = State.clocks(b)

    a = State.join(a, alice, "lobby", :alice)
    assert {b, [{_, {{:alice, _}, _}}], []} = State.merge(b, State.extract_delta(a))
    assert {{:b, 1}, %{{:a, 1} => 3, {:b, 1} => 1}} = State.clocks(b)
    assert Enum.empty?(b.cloud)
  end

  test "basic netsplit" do
    a = newp(:a)
    b = newp(:b)
    {a, _, _} = State.node_up(a, b.replica)
    {b, _, _} = State.node_up(b, a.replica)

    alice = new_conn
    bob = new_conn
    carol = new_conn
    david = new_conn

    a = State.join(a, alice, "lobby", :alice)
    b = State.join(b, bob, "lobby", :bob)

    {a, [{_, {{:bob,_}, _}}], _} = State.merge(a, State.extract(b))

    assert [:alice, :bob] = a |> State.online_list() |> keys()

    a = State.join(a, carol, "lobby", :carol)
    a = State.leave(a, alice, "lobby", :alice)
    a = State.join(a, david, "lobby", :david)

    assert {a,[],[{_,{{:bob,_}, _}}]} = State.node_down(a, {:b,1})

    assert [:carol, :david] = keys(State.online_list(a))

    assert {a,[],[]} = State.merge(a, State.extract(b))
    assert [:carol, :david] = keys(State.online_list(a))

    assert {a,[{_,{{:bob,_}, _}}],[]} = State.node_up(a, {:b,1})

    assert [:bob, :carol, :david] = keys(State.online_list(a))
  end

  test "get_by_pid" do
    pid = self()
    state = newp(:node1)

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
    state = newp(:node1)

    assert [] = State.get_by_topic(state, "topic")
    state = State.join(state, pid, "topic", "key1", %{})
    state = State.join(state, pid, "topic", "key2", %{})
    assert [{{^pid, "topic"}, {{"key1", %{}}, {{:node1, 1}, 1}}},
            {{^pid, "topic"}, {{"key2", %{}}, {{:node1, 1}, 2}}}] =
           State.get_by_topic(state, "topic")

    assert [] = State.get_by_topic(state, "another:topic")
  end

  test "remove_down_nodes" do
    state1 = newp(:node1)
    state2 = newp(:node2)
    {state1, _, _} = State.node_up(state1, state2.replica)
    {state2, _, _} = State.node_up(state2, state1.replica)

    alice = new_conn
    bob = new_conn

    state1 = State.join(state1, alice, "lobby", :alice)
    state2 = State.join(state2, bob, "lobby", :bob)
    {state2, _, _} = State.merge(state2, State.extract(state1))
    assert keys(State.online_list(state2)) == [:alice, :bob]

    {state2, _, _} = State.node_down(state2, {:node1, 1})
    state2 = State.remove_down_nodes(state2, {:node1, 1})
    {state2, _, _} = State.node_up(state2, {:node1, 1})
    assert keys(State.online_list(state2)) == [:bob]
  end
end
