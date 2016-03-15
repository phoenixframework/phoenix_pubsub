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

  test "that this is set up correctly" do
    a = newp(:a)
    assert [] = State.online_users(a)
    # assert [] = State.offline_users(a)
  end

  test "user added online is online" do
    a = newp(:a)
    john = new_conn()
    a = State.join(a, john, "lobby", :john)
    assert [:john] = State.online_users(a)
    a = State.leave(a, john, "lobby", :john)
    assert [] = State.online_users(a)
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
    assert {a,[{_,{{_,:bob,_}, _}}],[]} = State.merge(a, State.extract(b))
    assert [:alice,:bob] = State.online_users(a) |> Enum.sort

    # Merging twice doesn't dupe events
    assert {^a,[],[]} = State.merge(a, State.extract(b))

    assert {b,[{_,{{_,:alice,_}, _}}],[]} = State.merge(b, State.extract(a))
    assert {^b,[],[]} = State.merge(b, State.extract(a))
    a = State.leave(a, alice, "lobby", :alice)
    assert {b,[],[{_,{{_,:alice,_}, _}}]} = State.merge(b, State.extract(a))

    assert [:bob] = State.online_users(b) |> Enum.sort
    assert {^b,[],[]} = State.merge(b, State.extract(a))

    b = State.join(b, carol, "lobby", :carol)

    assert [:bob, :carol] = State.online_users(b) |> Enum.sort
    assert {a,[{_,{{_,:carol,_}, _}}],[]} = State.merge(a, State.extract(b))
    assert {^a,[],[]} = State.merge(a, State.extract(b))

    assert (State.online_users(b) |> Enum.sort) == (State.online_users(a) |> Enum.sort)

  end

  test "basic deltas" do
    a = newp(:a)
    b = newp(:b)

    alice = new_conn
    bob = new_conn

    a = State.join(a, alice, "lobby", :alice)
    b = State.join(b, bob, "lobby", :bob)

    assert {b, [{_, {{_, :alice, _}, _}}], []} = State.merge(b, State.extract_delta(a))

    a = State.reset_delta(a)
    a = State.leave(a, alice, "lobby", :alice)

    assert {_, [], [{_, {{_, :alice, _}, _}}]} = State.merge(b, State.extract_delta(a))
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

    {a, [{_, {{_,:bob,_}, _}}], _} = State.merge(a, State.extract(b))

    assert [:alice, :bob] = State.online_users(a) |> Enum.sort

    a = State.join(a, carol, "lobby", :carol)
    a = State.leave(a, alice, "lobby", :alice)
    a = State.join(a, david, "lobby", :david)

    assert {a,[],[{_,{{_,:bob,_}, _}}]} = State.node_down(a, {:b,1})

    assert [:carol, :david] = State.online_users(a) |> Enum.sort

    assert {a,[],[]} = State.merge(a, State.extract(b))
    assert [:carol, :david] = State.online_users(a) |> Enum.sort

    assert {a,[{_,{{_,:bob,_}, _}}],[]} = State.node_up(a, {:b,1})

    assert [:bob, :carol, :david] = State.online_users(a) |> Enum.sort
  end

  test "get_by_pid" do
    pid = self()
    state = newp(:node1)

    assert [] = State.get_by_pid(state, pid)
    state = State.join(state, pid, "topic", "key1", %{})
    assert [{^pid, {{"topic", "key1", %{}}, {{:node1, 1}, 1}}}] =
           State.get_by_pid(state, pid)

    assert {^pid, {{"topic", "key1", %{}}, {{:node1, 1}, 1}}} =
           State.get_by_pid(state, pid, "topic", "key1")

    assert State.get_by_pid(state, pid, "notopic", "key1") == nil
    assert State.get_by_pid(state, pid, "notopic", "nokey") == nil
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
    assert Enum.sort(State.online_users(state2)) == [:alice, :bob]

    {state2, _, _} = State.node_down(state2, {:node1, 1})
    state2 = State.remove_down_nodes(state2, {:node1, 1})
    {state2, _, _} = State.node_up(state2, {:node1, 1})
    assert State.online_users(state2) == [:bob]
  end

end
