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
    assert [] = TrackerState.offline_users(a)
  end

  test "user added online is online" do
    a = newp(:a)
    john = new_conn()
    a = TrackerState.join(a, john, "lobby", :john)
    assert [:john] = TrackerState.online_users(a)
    a = TrackerState.part(a, john, "lobby")
    assert [] = TrackerState.online_users(a)
  end

  test "users from other servers merge" do
    a = newp(:a)
    b = newp(:b)

    alice = new_conn
    bob = new_conn
    carol = new_conn

    a = TrackerState.join(a, alice, "lobby", :alice)
    b = TrackerState.join(b, bob, "lobby", :bob)

    # Merging emits a bob join event
    assert {a,[{_,{_,_,:bob,_}}],[]} = TrackerState.merge(a, b)
    assert [:alice,:bob] = TrackerState.online_users(a) |> Enum.sort

    # Merging twice doesn't dupe events
    assert {^a,[],[]} = TrackerState.merge(a, b)

    assert {b,[{_,{_,_,:alice,_}}],[]} = TrackerState.merge(b, a)
    assert {^b,[],[]} = TrackerState.merge(b, a)
    a = TrackerState.part(a, alice, "lobby")
    assert {b,[],[{_,{_,_,:alice,_}}]} = TrackerState.merge(b, a)

    assert [:bob] = TrackerState.online_users(b) |> Enum.sort
    assert {^b,[],[]} = TrackerState.merge(b, a)

    b = TrackerState.join(b, carol, "lobby", :carol)

    assert [:bob, :carol] = TrackerState.online_users(b) |> Enum.sort
    assert {a,[{_,{_,_,:carol,_}}],[]} = TrackerState.merge(a, b)
    assert {^a,[],[]} = TrackerState.merge(a, b)

    assert (TrackerState.online_users(b) |> Enum.sort) == (TrackerState.online_users(a) |> Enum.sort)

  end

  test "basic deltas" do
    a = newp(:a)
    b = newp(:b)

    alice = new_conn
    bob = new_conn

    a = TrackerState.join(a, alice, "lobby", :alice)
    b = TrackerState.join(b, bob, "lobby", :bob)

    {a, d_a} = TrackerState.delta_reset(a)
    assert {b, [{_, {_, _, :alice, _}}], []} = TrackerState.merge(b, d_a)

    a = TrackerState.part(a, alice, "lobby")
    d_a2 = TrackerState.delta(a)
    assert {_, [], [{_, {_, _, :alice, _}}]} = TrackerState.merge(b, d_a2)
  end

  test "basic netsplit" do
    a = newp(:a)
    b = newp(:b)

    alice = new_conn
    bob = new_conn
    carol = new_conn
    david = new_conn

    a = TrackerState.join(a, alice, "lobby", :alice)
    b = TrackerState.join(b, bob, "lobby", :bob)
    {a, [{_, {_,_,:bob,_}}], _} = TrackerState.merge(a, b)

    assert [:alice, :bob] = TrackerState.online_users(a) |> Enum.sort

    a = TrackerState.join(a, carol, "lobby", :carol)
    a = TrackerState.part(a, alice, "lobby")
    a = TrackerState.join(a, david, "lobby", :david)
    assert {a,[],[{_,{_,_,:bob,_}}]} = TrackerState.node_down(a, {:b,1})

    assert [:carol, :david] = TrackerState.online_users(a) |> Enum.sort

    assert {a,[],[]} = TrackerState.merge(a, b)
    assert [:carol, :david] = TrackerState.online_users(a) |> Enum.sort

    assert {a,[{_,{_,_,:bob,_}}],[]} = TrackerState.node_up(a, {:b,1})

    assert [:bob, :carol, :david] = TrackerState.online_users(a) |> Enum.sort
  end

  test "get_by_conn" do
    pid = self()
    state = newp(:node1)

    assert [] = TrackerState.get_by_conn(state, pid)
    state = TrackerState.join(state, pid, "topic", "key1", %{})
    assert [{{{:node1, 1}, 1}, {^pid, "topic", "key1", %{}}}] =
           TrackerState.get_by_conn(state, pid)

    assert {{{:node1, 1}, 1}, {^pid, "topic", "key1", %{}}} =
           TrackerState.get_by_conn(state, pid, "topic")

    assert TrackerState.get_by_conn(state, pid, "notopic") == nil
  end
end
