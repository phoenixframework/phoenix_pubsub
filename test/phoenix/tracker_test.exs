defmodule Phoenix.TrackerTest do
  use ExUnit.Case, async: true
  @opts [pubsub_server: nil, name: nil]

  test "validates down_period" do
    opts = Keyword.merge(@opts, [down_period: 1])
    assert Phoenix.Tracker.init([nil, nil, opts]) == {:error, "down_period must be at least twice as large as the broadcast_period"}
  end

  test "validates permdown_period" do
    opts = Keyword.merge(@opts, [permdown_period: 1_200_00, down_period: 1_200_000])
    assert Phoenix.Tracker.init([nil, nil, opts]) == {:error, "permdown_period must be at least larger than the down_period"}
  end
end
