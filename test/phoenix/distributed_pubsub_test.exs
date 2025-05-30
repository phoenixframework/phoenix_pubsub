defmodule Phoenix.PubSub.DistributedTest do
  use Phoenix.PubSub.NodeCase

  alias Phoenix.PubSub

  @node1 :"node1@127.0.0.1"
  @node2 :"node2@127.0.0.1"
  @node3 :"node3@127.0.0.1"
  @node4 :"node4@127.0.0.1"

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

  test "broadcast is received by other node that has running_pool_size > broadcast_pool_size", config do
    spy_on_pubsub(@node1, config.pubsub, self(), config.topic)
    # node3 has running_pool_size = 4, broadcast_pool_size = 1
    spy_on_pubsub(@node3, config.pubsub, self(), config.topic)
    :ok = PubSub.broadcast(config.pubsub, config.topic, :ping)
    assert_receive {@node3, :ping}
  end

  test "broadcast is received by other node that was broadcast from node that has broadcast_pool_size < pool_size", config do
    # node4 has pool_size = 1, message is sent from node3 that has running_pool_size = 4, broadcast_pool_size = 1
    spy_on_pubsub(@node1, config.pubsub, self(), config.topic)
    spy_on_pubsub(@node2, config.pubsub, self(), config.topic)
    spy_on_pubsub(@node3, config.pubsub, self(), config.topic)
    spy_on_pubsub(@node4, config.pubsub, self(), config.topic)

    broadcast_from_node(@node3, config.pubsub, config.topic, :ping)

    assert_receive {@node1, :ping}
    assert_receive {@node2, :ping}
    assert_receive {@node3, :ping}
    assert_receive {@node4, :ping}
  end
end
