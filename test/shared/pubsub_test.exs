defmodule Phoenix.PubSubTest do
  @moduledoc """
  Sets up PubSub Adapter testcases.

  ## Usage

  To test a PubSub adapter, set the `:test_adapter` on the `:phoenix_pubsub`
  configuration and require this file, ie:

      # your_pubsub_adapter_test.exs
      Application.put_env(:phoenix_pubsub, :test_adapter, {Phoenix.PubSub.PG2, []})
      Code.require_file "../deps/phoenix_pubsub/test/shared/pubsub_test.exs", __DIR__

  """

  use ExUnit.Case, async: true
  alias Phoenix.PubSub

  defp subscribers(config, topic) do
    Registry.lookup(config.pubsub, topic)
  end

  defp rpc(pid, func) do
    Agent.get(pid, fn :ok -> func.() end)
  end

  defp spawn_pid do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    pid
  end

  defmodule CustomDispatcher do
    def dispatch(entries, from, message) do
      for {pid, metadata} <- entries do
        send(pid, {:custom, metadata, from, message})
      end

      :ok
    end
  end

  # Models a dispatcher with its own metadata protocol alongside an ordinary
  # delivery branch, which is where tagged subscriptions are applied.
  defmodule TagAwareDispatcher do
    def dispatch(entries, from, message) do
      for {pid, metadata} <- entries, pid != from do
        case metadata do
          {:fastlane, target} -> send(target, {:fastlaned, message})
          metadata -> send(pid, {:custom, PubSub.tag_message(metadata, message)})
        end
      end

      :ok
    end
  end

  setup config do
    size = config[:pool_size] || 1
    registry_size = config[:registry_size] || config[:registry_pool_size] || config[:pool_size] ||  1
    {adapter, adapter_opts} = Application.get_env(:phoenix_pubsub, :test_adapter)
    adapter_opts = [adapter: adapter, name: config.test, pool_size: size, registry_size: registry_size] ++ adapter_opts
    start_supervised!({Phoenix.PubSub, adapter_opts})

    opts = %{
      pubsub: config.test,
      topic: to_string(config.test),
      pool_size: size,
      node: Phoenix.PubSub.node_name(config.test),
      adapter_name: Module.concat(config.test, "Adapter")
    }

    {:ok, opts}
  end

  test "node_name/1 returns the node name", config do
    assert is_atom(config.node) or is_binary(config.node)
  end

  for size <- [1, 8] do
    @tag pool_size: size
    test "pool #{size}: subscribe and unsubscribe", config do
      pid = spawn_pid()
      assert subscribers(config, config.topic) |> length == 0
      assert rpc(pid, fn -> PubSub.subscribe(config.pubsub, config.topic) end)
      assert subscribers(config, config.topic) == [{pid, nil}]
      assert rpc(pid, fn -> PubSub.unsubscribe(config.pubsub, config.topic) end)
      assert subscribers(config, config.topic) |> length == 0
    end

    @tag pool_size: size
    test "pool #{size}: subscribe and unsubscribe with metadata", config do
      pid = spawn_pid()
      pid2 = spawn_pid()
      assert subscribers(config, config.topic) |> length == 0

      # Subscribe with different metadata variants
      assert rpc(pid, fn ->
               PubSub.subscribe(config.pubsub, config.topic, metadata: :custom)
             end)

      assert rpc(pid, fn ->
               PubSub.subscribe(config.pubsub, config.topic, metadata: :other)
             end)

      assert rpc(pid2, fn -> PubSub.subscribe(config.pubsub, config.topic) end)

      # Verify all subscriptions exist
      assert length(subscribers(config, config.topic)) == 3
      assert {pid, :custom} in subscribers(config, config.topic)
      assert {pid, :other} in subscribers(config, config.topic)
      assert {pid2, nil} in subscribers(config, config.topic)

      # Unsubscribe only the :custom metadata subscription
      assert rpc(pid, fn -> PubSub.unsubscribe_match(config.pubsub, config.topic, :custom) end)

      # Verify only :custom was removed, others remain
      assert length(subscribers(config, config.topic)) == 2
      assert {pid, :other} in subscribers(config, config.topic)
      assert {pid2, nil} in subscribers(config, config.topic)
      refute {pid, :custom} in subscribers(config, config.topic)
    end

    @tag pool_size: size
    test "pool #{size}: subscribe with :tag delivers {tag, message}", config do
      tag = make_ref()
      assert PubSub.subscribe(config.pubsub, config.topic, tag: tag) == :ok

      PubSub.broadcast(config.pubsub, config.topic, :ping)
      assert_receive {^tag, :ping}

      PubSub.local_broadcast(config.pubsub, config.topic, :local)
      assert_receive {^tag, :local}
    end

    @tag pool_size: size
    test "pool #{size}: tagged and untagged subscriptions each receive their own message",
         config do
      tag1 = make_ref()
      tag2 = make_ref()
      assert PubSub.subscribe(config.pubsub, config.topic, tag: tag1) == :ok
      assert PubSub.subscribe(config.pubsub, config.topic, tag: tag2) == :ok
      assert PubSub.subscribe(config.pubsub, config.topic) == :ok

      PubSub.broadcast(config.pubsub, config.topic, :ping)
      assert_receive {^tag1, :ping}
      assert_receive {^tag2, :ping}
      assert_receive :ping
      refute_received _
    end

    @tag pool_size: size
    test "pool #{size}: broadcast_from/4 skips the sender's tagged subscriptions", config do
      tag = make_ref()
      assert PubSub.subscribe(config.pubsub, config.topic, tag: tag) == :ok

      # broadcast from another process: we are not the sender, so we get it tagged
      PubSub.broadcast_from(config.pubsub, spawn_pid(), config.topic, :ping)
      assert_receive {^tag, :ping}

      # broadcast from ourselves: our tagged subscription is skipped
      PubSub.broadcast_from(config.pubsub, self(), config.topic, :skipped)
      refute_receive {^tag, :skipped}

      PubSub.local_broadcast_from(config.pubsub, self(), config.topic, :skipped)
      refute_receive {^tag, :skipped}
    end

    @tag pool_size: size
    test "pool #{size}: unsubscribe/3 with :tag drops only that subscription", config do
      tag1 = make_ref()
      tag2 = make_ref()
      assert PubSub.subscribe(config.pubsub, config.topic, tag: tag1) == :ok
      assert PubSub.subscribe(config.pubsub, config.topic, tag: tag2) == :ok
      assert PubSub.subscribe(config.pubsub, config.topic) == :ok
      assert length(subscribers(config, config.topic)) == 3

      assert PubSub.unsubscribe(config.pubsub, config.topic, tag: tag1) == :ok
      assert length(subscribers(config, config.topic)) == 2

      PubSub.broadcast(config.pubsub, config.topic, :ping)
      refute_receive {^tag1, :ping}
      assert_receive {^tag2, :ping}
      assert_receive :ping
    end

    @tag pool_size: size
    test "pool #{size}: unsubscribe/2 drops tagged and untagged subscriptions alike", config do
      tag = make_ref()
      assert PubSub.subscribe(config.pubsub, config.topic, tag: tag) == :ok
      assert PubSub.subscribe(config.pubsub, config.topic) == :ok
      assert length(subscribers(config, config.topic)) == 2

      assert PubSub.unsubscribe(config.pubsub, config.topic) == :ok
      assert subscribers(config, config.topic) == []
    end

    @tag pool_size: size
    test "pool #{size}: unsubscribe/3 with an unknown tag noops", config do
      tag = make_ref()
      assert PubSub.subscribe(config.pubsub, config.topic, tag: tag) == :ok
      assert PubSub.unsubscribe(config.pubsub, config.topic, tag: make_ref()) == :ok
      assert length(subscribers(config, config.topic)) == 1
    end

    @tag pool_size: size
    test "pool #{size}: unsubscribe/3 treats match spec atoms as ordinary tags", config do
      assert PubSub.subscribe(config.pubsub, config.topic, tag: :normal) == :ok
      assert PubSub.subscribe(config.pubsub, config.topic, tag: {:comp, 1}) == :ok
      assert length(subscribers(config, config.topic)) == 2

      # :_ and :"$1" are wildcards in a match spec and must not match anything
      # other than a subscription tagged with that exact term
      assert PubSub.unsubscribe(config.pubsub, config.topic, tag: :_) == :ok
      assert PubSub.unsubscribe(config.pubsub, config.topic, tag: :"$1") == :ok
      assert length(subscribers(config, config.topic)) == 2

      assert PubSub.unsubscribe(config.pubsub, config.topic, tag: {:comp, 1}) == :ok
      assert length(subscribers(config, config.topic)) == 1

      PubSub.broadcast(config.pubsub, config.topic, :ping)
      assert_receive {:normal, :ping}
      refute_received _
    end

    @tag pool_size: size
    test "pool #{size}: tags survive a custom dispatcher calling tag_message/2", config do
      tag = make_ref()
      assert PubSub.subscribe(config.pubsub, config.topic, tag: tag) == :ok
      assert PubSub.subscribe(config.pubsub, config.topic) == :ok

      # a subscription using the dispatcher's own metadata protocol takes the
      # custom branch and is unaffected by tagging
      assert PubSub.subscribe(config.pubsub, config.topic,
               metadata: {:fastlane, self()}
             ) == :ok

      PubSub.broadcast(config.pubsub, config.topic, :ping, TagAwareDispatcher)
      assert_receive {:custom, {^tag, :ping}}
      assert_receive {:custom, :ping}
      assert_receive {:fastlaned, :ping}
      refute_received _
    end

    @tag pool_size: size
    test "pool #{size}: subscribe raises when given both :tag and :metadata", config do
      assert_raise ArgumentError, ~r/cannot pass both :tag and :metadata/, fn ->
        PubSub.subscribe(config.pubsub, config.topic, tag: make_ref(), metadata: :custom)
      end

      assert subscribers(config, config.topic) == []
    end

    @tag pool_size: size
    test "pool #{size}: broadcast/3 and broadcast!/3 publishes message to each subscriber",
         config do
      PubSub.subscribe(config.pubsub, config.topic)
      :ok = PubSub.broadcast(config.pubsub, config.topic, :ping)
      assert_receive :ping
      :ok = PubSub.broadcast!(config.pubsub, config.topic, :ping)
      assert_receive :ping
    end

    @tag pool_size: size
    test "pool #{size}: broadcast/3 does not publish message to other topic subscribers",
         config do
      PubSub.subscribe(config.pubsub, "unknown")

      Enum.each(0..10, fn _ ->
        rpc(spawn_pid(), fn -> PubSub.subscribe(config.pubsub, config.topic) end)
      end)

      :ok = PubSub.broadcast(config.pubsub, config.topic, :ping)
      refute_received :ping
    end

    @tag pool_size: size
    test "pool #{size}: broadcast_from/4 and broadcast_from!/4 skips sender", config do
      PubSub.subscribe(config.pubsub, config.topic)

      PubSub.broadcast_from(config.pubsub, self(), config.topic, :ping)
      refute_received :ping

      PubSub.broadcast_from!(config.pubsub, self(), config.topic, :ping)
      refute_received :ping
    end

    @tag pool_size: size
    test "pool #{size}: unsubscribe on not subscribed topic noops", config do
      assert :ok = PubSub.unsubscribe(config.pubsub, config.topic)
      assert subscribers(config, config.topic) == []
    end

    @tag pool_size: size
    test "pool #{size}: direct_broadcast sends to given node", config do
      PubSub.subscribe(config.pubsub, config.topic)

      PubSub.direct_broadcast(config.node, config.pubsub, config.topic, :ping)
      assert_receive :ping

      PubSub.direct_broadcast!(config.node, config.pubsub, config.topic, :ping)
      assert_receive :ping
    end

    @tag pool_size: size
    test "pool #{size}: direct_broadcast sends to unknown node", config do
      PubSub.subscribe(config.pubsub, config.topic)

      PubSub.direct_broadcast(:"IDONTKNOW@127.0.0.1", config.pubsub, config.topic, :ping)
      refute_received :ping

      PubSub.direct_broadcast!(:"IDONTKNOW@127.0.0.1", config.pubsub, config.topic, :ping)
      refute_received :ping
    end

    @tag pool_size: size
    test "pool #{size}: local_broadcast sends to the current node", config do
      PubSub.subscribe(config.pubsub, config.topic)

      PubSub.local_broadcast(config.pubsub, config.topic, :ping)
      assert_receive :ping
    end

    @tag pool_size: size
    test "pool #{size}: local_broadcast_from/5 skips sender", config do
      PubSub.subscribe(config.pubsub, config.topic)

      PubSub.local_broadcast_from(config.pubsub, self(), config.topic, :ping)
      refute_received :ping
    end

    @tag pool_size: size
    test "pool #{size}: with custom dispatching", %{topic: topic, test: test, node: node} do
      PubSub.subscribe(test, topic)
      PubSub.subscribe(test, topic, metadata: :special)

      PubSub.broadcast(test, topic, :broadcast, CustomDispatcher)
      assert_receive {:custom, nil, :none, :broadcast}
      assert_receive {:custom, :special, :none, :broadcast}

      PubSub.broadcast_from(test, self(), topic, :broadcast_from, CustomDispatcher)
      assert_receive {:custom, nil, pid, :broadcast_from} when pid == self()
      assert_receive {:custom, :special, pid, :broadcast_from} when pid == self()

      PubSub.local_broadcast(test, topic, :local, CustomDispatcher)
      assert_receive {:custom, nil, :none, :local}
      assert_receive {:custom, :special, :none, :local}

      PubSub.local_broadcast_from(test, self(), topic, :local_from, CustomDispatcher)
      assert_receive {:custom, nil, pid, :local_from} when pid == self()
      assert_receive {:custom, :special, pid, :local_from} when pid == self()

      PubSub.direct_broadcast(node, test, topic, :direct, CustomDispatcher)
      assert_receive {:custom, nil, :none, :direct}
      assert_receive {:custom, :special, :none, :direct}
    end
  end

  @tag pool_size: 4
  @tag registry_size: 2
  test "PubSub pool size can be configured separately from the Registry partitions",
       config do
    assert_ets_duplicate_count(config.pubsub, 2)

    assert :persistent_term.get(config.adapter_name) ==
      {config.adapter_name, :"#{config.adapter_name}_2", :"#{config.adapter_name}_3", :"#{config.adapter_name}_4"}
  end

  @tag pool_size: 3
  test "Registry partitions are configured with the same pool size as PubSub if not specified",
       config do
    assert_ets_duplicate_count(config.pubsub, 3)

    assert :persistent_term.get(config.adapter_name) ==
      {config.adapter_name, :"#{config.adapter_name}_2", :"#{config.adapter_name}_3"}
  end

  defp assert_ets_duplicate_count(pubsub, count) do
    result = :ets.lookup_element(pubsub, -2, 2)

    if Version.match?(System.version(), ">= 1.19.0") do
      assert {{:duplicate, :pid}, ^count, _} = result
    else
      assert {:duplicate, ^count, _} = result
    end
  end
end
