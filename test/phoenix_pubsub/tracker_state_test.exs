defmodule Phoenix.TrackerStateTest do
  use ExUnit.Case

  alias Phoenix.Tracker.State, as: TrackerState

  # Partial netsplit multiple joins

  # New print-callback Presence
  defp newp(node) do
    TrackerState.new({node, 1})
  end

  defp new_conn() do
    make_ref()
  end

  test "that this is set up correctly" do
    a = newp(:a)
    assert [] = TrackerState.online_users(a)
    # assert [] = TrackerState.offline_users(a)
  end

  test "user added online is online" do
    a = newp(:a)
    john = new_conn()
    a = TrackerState.join(a, john, "lobby", :john)
    assert [:john] = TrackerState.online_users(a)
    a = TrackerState.leave(a, john, "lobby", :john)
    assert [] = TrackerState.online_users(a)
  end

  test "users from other servers merge" do
    a = newp(:a)
    b = newp(:b)
    {a, _, _} = TrackerState.node_up(a, b.replica)
    {b, _, _} = TrackerState.node_up(b, a.replica)

    alice = new_conn
    bob = new_conn
    carol = new_conn

    a = TrackerState.join(a, alice, "lobby", :alice)
    b = TrackerState.join(b, bob, "lobby", :bob)

    # Merging emits a bob join event
    assert {a,[{_,{{_,:bob,_}, _}}],[]} = TrackerState.merge(a, TrackerState.extract(b))
    assert [:alice,:bob] = TrackerState.online_users(a) |> Enum.sort

    # Merging twice doesn't dupe events
    assert {^a,[],[]} = TrackerState.merge(a, TrackerState.extract(b))

    assert {b,[{_,{{_,:alice,_}, _}}],[]} = TrackerState.merge(b, TrackerState.extract(a))
    assert {^b,[],[]} = TrackerState.merge(b, TrackerState.extract(a))
    a = TrackerState.leave(a, alice, "lobby", :alice)
    assert {b,[],[{_,{{_,:alice,_}, _}}]} = TrackerState.merge(b, TrackerState.extract(a))

    assert [:bob] = TrackerState.online_users(b) |> Enum.sort
    assert {^b,[],[]} = TrackerState.merge(b, TrackerState.extract(a))

    b = TrackerState.join(b, carol, "lobby", :carol)

    assert [:bob, :carol] = TrackerState.online_users(b) |> Enum.sort
    assert {a,[{_,{{_,:carol,_}, _}}],[]} = TrackerState.merge(a, TrackerState.extract(b))
    assert {^a,[],[]} = TrackerState.merge(a, TrackerState.extract(b))

    assert (TrackerState.online_users(b) |> Enum.sort) == (TrackerState.online_users(a) |> Enum.sort)

  end

  # test "basic deltas" do
  #   a = newp(:a)
  #   b = newp(:b)

  #   alice = new_conn
  #   bob = new_conn

  #   a = TrackerState.join(a, alice, "lobby", :alice)
  #   b = TrackerState.join(b, bob, "lobby", :bob)

  #   {a, d_a} = TrackerState.delta_reset(a)
  #   assert {b, [{_, {_, _, :alice, _}}], []} = TrackerState.merge(b, d_a)

  #   a = TrackerState.leave(a, alice, "lobby", :alice)
  #   d_a2 = TrackerState.delta(a)
  #   assert {_, [], [{_, {_, _, :alice, _}}]} = TrackerState.merge(b, d_a2)
  # end

  test "basic netsplit" do
    a = newp(:a)
    b = newp(:b)
    {a, _, _} = TrackerState.node_up(a, b.replica)
    {b, _, _} = TrackerState.node_up(b, a.replica)

    alice = new_conn
    bob = new_conn
    carol = new_conn
    david = new_conn

    a = TrackerState.join(a, alice, "lobby", :alice)
    b = TrackerState.join(b, bob, "lobby", :bob)

    {a, [{_, {{_,:bob,_}, _}}], _} = TrackerState.merge(a, TrackerState.extract(b))

    assert [:alice, :bob] = TrackerState.online_users(a) |> Enum.sort

    a = TrackerState.join(a, carol, "lobby", :carol)
    a = TrackerState.leave(a, alice, "lobby", :alice)
    a = TrackerState.join(a, david, "lobby", :david)

    assert {a,[],[{_,{{_,:bob,_}, _}}]} = TrackerState.node_down(a, {:b,1})

    assert [:carol, :david] = TrackerState.online_users(a) |> Enum.sort

    assert {a,[],[]} = TrackerState.merge(a, TrackerState.extract(b))
    assert [:carol, :david] = TrackerState.online_users(a) |> Enum.sort

    assert {a,[{_,{{_,:bob,_}, _}}],[]} = TrackerState.node_up(a, {:b,1})

    assert [:bob, :carol, :david] = TrackerState.online_users(a) |> Enum.sort
  end

  test "get_by_pid" do
    pid = self()
    state = newp(:node1)

    assert [] = TrackerState.get_by_pid(state, pid)
    state = TrackerState.join(state, pid, "topic", "key1", %{})
    assert [{^pid, {{"topic", "key1", %{}}, {{:node1, 1}, 1}}}] =
           TrackerState.get_by_pid(state, pid)

    assert {^pid, {{"topic", "key1", %{}}, {{:node1, 1}, 1}}} =
           TrackerState.get_by_pid(state, pid, "topic", "key1")

    assert TrackerState.get_by_pid(state, pid, "notopic", "key1") == nil
    assert TrackerState.get_by_pid(state, pid, "notopic", "nokey") == nil
  end

  test "remove_down_nodes" do
    state1 = newp(:node1)
    state2 = newp(:node2)
    {state1, _, _} = TrackerState.node_up(state1, state2.replica)
    {state2, _, _} = TrackerState.node_up(state2, state1.replica)

    alice = new_conn
    bob = new_conn

    state1 = TrackerState.join(state1, alice, "lobby", :alice)
    state2 = TrackerState.join(state2, bob, "lobby", :bob)
    {state2, _, _} = TrackerState.merge(state2, TrackerState.extract(state1))
    assert Enum.sort(TrackerState.online_users(state2)) == [:alice, :bob]

    {state2, _, _} = TrackerState.node_down(state2, {:node1, 1})
    state2 = TrackerState.remove_down_nodes(state2, {:node1, 1})
    {state2, _, _} = TrackerState.node_up(state2, {:node1, 1})
    assert TrackerState.online_users(state2) == [:bob]
  end

end
