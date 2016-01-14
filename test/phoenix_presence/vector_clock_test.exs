defmodule Phoenix.Presence.VectorClockTest do
  use ExUnit.Case, async: true
  alias Phoenix.Presence.VectorClock


  test "merge" do
    my_clocks = %{me: 1, n2: 3, n3: 3}
    remote_clocks = %{me: 1, n2: 2, n3: 4}
    assert VectorClock.merge_clocks(:me, my_clocks, remote_clocks) ==
      %{me: 1, n2: 3, n3: 4}

    my_clocks = %{me: 1, n2: 3, n3: 8}
    remote_clocks = %{me: 2, n2: 2, n3: 4}
    assert VectorClock.merge_clocks(:me, my_clocks, remote_clocks) ==
      %{me: 1, n2: 3, n3: 8}

  end

  test "collapse_clocks" do
    my_clocks = %{me: 1, n2: 3, n3: 3, n4: 1}
    pending_clocks = %{
      n2: %{me: 1, n2: 3, n3: 4, n4: 1},
      n3: %{me: 1, n2: 4, n3: 5, n4: 1},
      n4: %{me: 1, n2: 4, n3: 5, n4: 2},
    }
    assert VectorClock.collapse_clocks(:me, my_clocks, pending_clocks) ==
      {%{me: 1, n2: 4, n3: 5, n4: 2}, %{n3: [n3: 5, n2: 4], n4: [n4: 2]}}


    my_clocks = %{me: 1, n2: 3, n3: 3, n4: 1}
    pending_clocks = %{
      n2: %{me: 1, n2: 3, n3: 4, n4: 1, n5: 1},
      n3: %{me: 1, n2: 4, n3: 5, n4: 1, n5: 2},
      n4: %{me: 1, n2: 4, n3: 5, n4: 2, n5: 1},
      n5: %{me: 1, n2: 4, n3: 5, n4: 1, n5: 2},
    }
    assert VectorClock.collapse_clocks(:me, my_clocks, pending_clocks) ==
      {%{me: 1, n2: 4, n3: 5, n4: 2, n5: 2}, %{n3: [n5: 2, n3: 5, n2: 4], n4: [n4: 2]}}


    my_clocks = %{me: 1, n2: 3, n3: 3, n4: 1}
    pending_clocks = %{
      n2: %{me: 1, n2: 2, n3: 3, n4: 1},
      n3: %{me: 1, n2: 2, n3: 3, n4: 1},
      n4: %{me: 1, n2: 2, n3: 3, n4: 1},
    }
    assert VectorClock.collapse_clocks(:me, my_clocks, pending_clocks) ==
      {%{me: 1, n2: 3, n3: 3, n4: 1}, %{}}

    my_clocks = %{me: 1, n2: 3, n3: 3, n4: 1}
    pending_clocks = %{
      n2: %{me: 1, n2: 2, n3: 3, n4: 1},
      n3: %{me: 1, n2: 2, n3: 3, n4: 1},
      n4: %{me: 1, n2: 2, n3: 3, n4: 1, n5: 1},
    }
    assert VectorClock.collapse_clocks(:me, my_clocks, pending_clocks) ==
      {%{me: 1, n2: 3, n3: 3, n4: 1, n5: 1},  %{n4: [n5: 1]}}
  end
end
