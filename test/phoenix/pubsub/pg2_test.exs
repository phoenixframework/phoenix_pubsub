# Run shared PubSub adapter tests
Application.put_env(:phoenix, :pubsub_test_adapter, Phoenix.PubSub.PG2)
Code.require_file "../../shared/pubsub_test.exs", __DIR__

# Run distributed elixir specific PubSub tests
defmodule Phoenix.PubSub.PG2Test do
  use Phoenix.PubSub.NodeCase
  alias Phoenix.PubSub
  alias Phoenix.PubSub.PG2

  @node1 :"node1@127.0.0.1"
  @node2 :"node2@127.0.0.1"

  setup config do
    size = config[:pool_size] || 1
    if config[:pool_size] do
      {:ok, _} = PG2.start_link(config.test, pool_size: size)
    else
      {:ok, _} = PG2.start_link(config.test, [])
    end
    {_, {:ok, _}} = start_pubsub(@node1, PG2, config.test, [pool_size: size])
    {:ok, %{pubsub: config.test, pool_size: size}}
  end

  for size <- [1, 8] do
    @tag pool_size: size
    test "pool #{size}: direct_broadcast targets a specific node", config do
      spy_on_pubsub(@node1, config.pubsub, self(), "some:topic")

      PubSub.subscribe(config.pubsub, "some:topic")
      :ok = PubSub.direct_broadcast(@node1, config.pubsub, "some:topic", :ping)
      assert_receive {@node1, :ping}
      :ok = PubSub.direct_broadcast!(@node1, config.pubsub, "some:topic", :ping)
      assert_receive {@node1, :ping}

      :ok = PubSub.direct_broadcast(@node2, config.pubsub, "some:topic", :ping)
      refute_receive {@node1, :ping}

      :ok = PubSub.direct_broadcast!(@node2, config.pubsub, "some:topic", :ping)
      refute_receive {@node1, :ping}
    end

    @tag pool_size: size
    test "pool #{size}: direct_broadcast_from targets a specific node", config do
      spy_on_pubsub(@node1, config.pubsub, self(), "some:topic")

      PubSub.subscribe(config.pubsub, "some:topic")
      :ok = PubSub.direct_broadcast_from(@node1, config.pubsub, self(), "some:topic", :ping)
      assert_receive {@node1, :ping}
      :ok = PubSub.direct_broadcast_from!(@node1, config.pubsub, self(), "some:topic", :ping)
      assert_receive {@node1, :ping}

      :ok = PubSub.direct_broadcast_from(@node2, config.pubsub, self(), "some:topic", :ping)
      refute_receive {@node1, :ping}

      :ok = PubSub.direct_broadcast_from!(@node2, config.pubsub, self(), "some:topic", :ping)
      refute_receive {@node1, :ping}
    end
  end

  test "pool size defaults to number of schedulers" do
    {:ok, pg2_supervisor} = PG2.start_link(:pool_size_count_test, [])
    local_supervisor =
      pg2_supervisor
      |> Supervisor.which_children()
      |> Enum.find_value(fn
          {Phoenix.PubSub.LocalSupervisor, pid, :supervisor, _} -> pid
          _                                                     -> false
        end)
    %{supervisors: supervisor_count} = Supervisor.count_children(local_supervisor)
    assert supervisor_count == :erlang.system_info(:schedulers)
  end
end
