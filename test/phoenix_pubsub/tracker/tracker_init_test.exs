defmodule Phoenix.Tracker.InitTest do
  use ExUnit.Case, async: true
  @opts [pubsub_server: nil, name: nil]

  test "down_period" do
    assert_raise ArgumentError, ~r/down_period/, fn ->
      opts = Keyword.merge(@opts, [down_period: 1])
      Phoenix.Tracker.init([nil, nil, opts])
    end
  end

  test "permdown_period" do
    assert_raise ArgumentError, ~r/permdown_period/, fn ->
      opts = Keyword.merge(@opts, [permdown_period: 1_200_00, down_period: 1_200_000])
      Phoenix.Tracker.init([nil, nil, opts])
    end
  end
end
