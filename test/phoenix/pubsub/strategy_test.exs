defmodule Phoenix.PubSub.StrategyTest do
  use ExUnit.Case, async: true

  test "Serial strategy executes fun in the same process" do
    test_pid = self()
    fun = fn(shard) -> send(test_pid, {self(), shard}) end
    Phoenix.PubSub.Strategy.Serial.run(50, fun)
    received_messages = for i <- 0..49 do
      assert_received {_pid, ^i}
    end
    assert [_] = Enum.map(received_messages, &elem(&1, 0)) |> Enum.uniq
  end

  test "Parallel strategy executes fun in separate processes" do
    test_pid = self()
    fun = fn(shard) -> send(test_pid, {self(), shard}) end
    Phoenix.PubSub.Strategy.Parallel.run(50, fun)
    received_messages = for i <- 0..49 do
      assert_received {_pid, ^i}
    end
    assert 50 = Enum.map(received_messages, &elem(&1, 0))
              |> Enum.uniq
              |> Enum.count
  end

end
