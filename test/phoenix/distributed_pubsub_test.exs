defmodule Phoenix.PubSub.DistributedTest do
  use Phoenix.PubSub.NodeCase

  alias Phoenix.PubSub

  @node1 :"node1@127.0.0.1"
  @node2 :"node2@127.0.0.1"

  setup config do
    {:ok, %{pubsub: Phoenix.PubSubTest, topic: Atom.to_string(config.test)}}
  end

  test "broadcast targets all nodes", config do
    spy_on_pubsub(@node1, config.pubsub, self(), config.topic)
    spy_on_pubsub(@node2, config.pubsub, self(), config.topic)

    :ok = PubSub.broadcast(config.pubsub, config.topic, :ping)
    assert_receive {@node1, :ping}
    assert_receive {@node2, :ping}

    :ok = PubSub.broadcast(config.pubsub, config.topic, :ping)
    assert_receive {@node1, :ping}
    assert_receive {@node2, :ping}
  end

  test "local_broadcast targets current nodes", config do
    spy_on_pubsub(@node1, config.pubsub, self(), config.topic)
    spy_on_pubsub(@node2, config.pubsub, self(), config.topic)

    PubSub.subscribe(config.pubsub, config.topic)
    :ok = PubSub.local_broadcast(config.pubsub, config.topic, :ping)
    refute_received {@node1, :ping}
    refute_received {@node2, :ping}
  end

  test "direct_broadcast targets a specific node", config do
    spy_on_pubsub(@node1, config.pubsub, self(), config.topic)

    :ok = PubSub.direct_broadcast(@node1, config.pubsub, config.topic, :ping)
    assert_receive {@node1, :ping}
    :ok = PubSub.direct_broadcast!(@node1, config.pubsub, config.topic, :ping)
    assert_receive {@node1, :ping}

    :ok = PubSub.direct_broadcast(@node2, config.pubsub, config.topic, :ping)
    refute_received {@node1, :ping}
    :ok = PubSub.direct_broadcast!(@node2, config.pubsub, config.topic, :ping)
    refute_received {@node1, :ping}
  end
end
