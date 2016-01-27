# Run shared PubSub adapter tests
Application.put_env(:phoenix, :pubsub_test_adapter, Phoenix.PubSub.PG2)
Code.require_file "../shared/pubsub_test.exs", __DIR__

# Run distributed elixir specific PubSub tests
defmodule Phoenix.PubSub.PG2Test do
  use Phoenix.PubSub.NodeCase
  alias Phoenix.PubSub
  alias Phoenix.PubSub.PG2

  @slave1 :"slave1@127.0.0.1"
  @slave2 :"slave2@127.0.0.1"

  setup config do
    size = config[:pool_size] || 1
    {:ok, _} = PG2.start_link(config.test, pool_size: size)
    {_, {:ok, _}} = start_pubsub(@slave1, PG2, config.test, [pool_size: size])
    {:ok, %{pubsub: config.test, pool_size: size}}
  end

  for size <- [1, 8] do
    @tag pool_size: size
    test "pool #{size}: direct_broadcast targets a specific node", config do
      spy_on_pubsub(@slave1, config.pubsub, self(), "some:topic")

      PubSub.subscribe(config.pubsub, self, "some:topic")
      :ok = PubSub.direct_broadcast(@slave1, config.pubsub, "some:topic", :ping)
      assert_receive {@slave1, :ping}
      :ok = PubSub.direct_broadcast!(@slave1, config.pubsub, "some:topic", :ping)
      assert_receive {@slave1, :ping}

      :ok = PubSub.direct_broadcast(@slave2, config.pubsub, "some:topic", :ping)
      refute_receive {@slave1, :ping}

      :ok = PubSub.direct_broadcast!(@slave2, config.pubsub, "some:topic", :ping)
      refute_receive {@slave1, :ping}
    end

    @tag pool_size: size
    test "pool #{size}: direct_broadcast_from targets a specific node", config do
      spy_on_pubsub(@slave1, config.pubsub, self(), "some:topic")

      PubSub.subscribe(config.pubsub, self, "some:topic")
      :ok = PubSub.direct_broadcast_from(@slave1, config.pubsub, self(), "some:topic", :ping)
      assert_receive {@slave1, :ping}
      :ok = PubSub.direct_broadcast_from!(@slave1, config.pubsub, self(), "some:topic", :ping)
      assert_receive {@slave1, :ping}

      :ok = PubSub.direct_broadcast_from(@slave2, config.pubsub, self(), "some:topic", :ping)
      refute_receive {@slave1, :ping}

      :ok = PubSub.direct_broadcast_from!(@slave2, config.pubsub, self(), "some:topic", :ping)
      refute_receive {@slave1, :ping}
    end
  end
end
