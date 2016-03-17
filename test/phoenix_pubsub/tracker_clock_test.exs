defmodule Phoenix.TrackerClockTest do
  use ExUnit.Case
  alias Phoenix.Tracker.Clock

  test "basic dominates" do
    clock1 = %{a: 1, b: 2, c: 3}
    clock2 = %{b: 2, c: 3, d: 1}
    clock3 = %{a: 1, b: 2}
    assert true == Clock.dominates?(clock1, clock3)
    assert false == Clock.dominates?(clock3, clock1)
    assert false == Clock.dominates?(clock1, clock2)
  end

  test "test the set trims..." do
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

end
