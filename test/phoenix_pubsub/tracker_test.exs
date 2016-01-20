defmodule Phoenix.TrackerTest do
  use ExUnit.Case, async: true


  setup config do
    pubsub = Module.concat(config.test, PubSub)
    {:ok, _} = Phoenix.PubSub.PG2.start_link(pubsub, pool_size: 1)
    {:ok, pid} = Phoenix.Tracker.start_link(
      name: config.test,
      node_name: :"tracker1@host",
      pubsub_server: pubsub,
      heartbeat_interval: 50,
    )
    {:ok, tracker: pid, pubsub: pubsub}
  end

  test "heartbeats after starting", config do
    Phoenix.PubSub.subscribe(config.pubsub, self(), "phx_presence:#{config.test}")
    assert_receive {:pub, :gossip, {:"tracker1@host", _vsn}, _clocks}
  end
end
