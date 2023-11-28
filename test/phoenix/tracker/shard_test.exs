defmodule Phoenix.Tracker.ShardTest do
  use ExUnit.Case, async: true
  @opts [pubsub_server: nil, name: nil]

  test "validates down_period" do
    opts = Keyword.merge(@opts, [down_period: 1])
    assert Phoenix.Tracker.Shard.init([nil, nil, opts]) ==
      {:error, "down_period must be at least twice as large as the broadcast_period"}
  end

  test "validates permdown_period" do
    opts = Keyword.merge(@opts, [permdown_period: 1_200_00, down_period: 1_200_000])
    assert Phoenix.Tracker.Shard.init([nil, nil, opts]) ==
      {:error, "permdown_period must be at least larger than the down_period"}
  end

  defmodule TestTracker do
    use Phoenix.Tracker
    def init(state), do: {:ok, state}
    def handle_diff(_diff, state), do: {:ok, state}
  end

  describe "size/1" do
    test "returns 0 when there are no entries in the shard" do
      tracker = TestTracker
      name = :"#{inspect(make_ref())}"
      shard_name = Phoenix.Tracker.Shard.name_for_number(name, 1)
      given_pubsub(name)
      opts = [pubsub_server: name, name: name, shard_number: 1]
      {:ok, _pid} = Phoenix.Tracker.Shard.start_link(tracker, %{}, opts)

      assert Phoenix.Tracker.Shard.size(shard_name) == 0
    end

    test "returns number of tracked entries in the shard" do
      tracker = TestTracker
      name = :"#{inspect(make_ref())}"
      shard_name = Phoenix.Tracker.Shard.name_for_number(name, 1)
      given_pubsub(name)
      opts = [pubsub_server: name, name: name, shard_number: 1]
      {:ok, pid} = Phoenix.Tracker.Shard.start_link(tracker, %{}, opts)

      for i <- 1..100 do
        Phoenix.Tracker.Shard.track(pid, self(), "topic", "user#{i}", %{})
      end

      assert Phoenix.Tracker.Shard.size(shard_name) == 100
    end

    defp given_pubsub(name) do
      size = 1
      {adapter, adapter_opts} = Application.get_env(:phoenix_pubsub, :test_adapter)
      adapter_opts = [adapter: adapter, name: name, pool_size: size] ++ adapter_opts
      start_supervised!({Phoenix.PubSub, adapter_opts})
    end
  end
end
