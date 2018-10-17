defmodule Phoenix.TrackerClockTest do
  use ExUnit.Case
  alias Phoenix.Tracker.Clock

  test "dominates?" do
    clock1 = %{a: 1, b: 2, c: 3}
    clock2 = %{b: 2, c: 3, d: 1}
    clock3 = %{a: 1, b: 2}
    assert Clock.dominates?(clock1, clock3)
    refute Clock.dominates?(clock3, clock1)
    refute Clock.dominates?(clock1, clock2)
    assert Clock.dominates?(clock1, clock1)
  end

  test "test the set trims" do
    clock1 = {:a, %{a: 1, b: 2, c: 3}}
    clock2 = {:b, %{b: 2, c: 3, d: 1}}
    clock3 = {:c, %{a: 1, b: 2}}
    assert [clock2, clock3] == Clock.append_clock([clock2, clock3], clock1) |> Enum.sort
    assert [clock1, clock2] == Clock.append_clock([clock1, clock2], clock3) |> Enum.sort
    assert [clock1, clock2] == Clock.append_clock([clock1, clock2], clock1) |> Enum.sort
    assert [clock1, clock2] == Clock.append_clock([clock1, clock2], clock2) |> Enum.sort
    assert [clock1, clock2, clock3] == Clock.append_clock([clock1, clock3], clock2) |> Enum.sort
    assert [:b, :c] == [clock2, clock3]
                       |> Clock.append_clock(clock1)
                       |> Clock.clockset_replicas()
                       |> Enum.sort()
  end

  test "upperbound" do
    assert Clock.upperbound(%{a: 1, b: 2, c: 2}, %{a: 3, b: 1, d: 2}) ==
      %{a: 3, b: 2, c: 2, d: 2}

    assert Clock.upperbound(%{}, %{a: 3, b: 1, d: 2}) == %{a: 3, b: 1, d: 2}
    assert Clock.upperbound(%{a: 3, b: 1, d: 2}, %{}) == %{a: 3, b: 1, d: 2}
  end

  test "lowerbound" do
    assert Clock.lowerbound(%{a: 1, b: 2, c: 2}, %{a: 3, b: 1, d: 2}) ==
      %{a: 1, b: 1, c: 2, d: 2}

    assert Clock.lowerbound(%{}, %{a: 3, b: 1, d: 2}) == %{a: 3, b: 1, d: 2}
    assert Clock.lowerbound(%{a: 3, b: 1, d: 2}, %{}) == %{a: 3, b: 1, d: 2}
  end

  test "filter replicas" do
    assert Clock.filter_replicas(%{a: 1, b: 2, c: 3}, [:a, :b]) == %{a: 1, b: 2}
    assert Clock.filter_replicas(%{a: 1, b: 2, c: 3}, [:a, :c]) == %{a: 1, c: 3}
    assert Clock.filter_replicas(%{a: 1, b: 2, c: 3}, [:a, :d]) == %{a: 1}
    assert Clock.filter_replicas(%{a: 1, b: 2, c: 3}, [:d]) == %{}
  end

  test "replicas" do
    assert Clock.replicas(%{}) == []
    assert Clock.replicas(%{a: 1}) == [:a]
    assert Clock.replicas(%{a: 1, b: 2}) == [:a, :b]
  end
end
