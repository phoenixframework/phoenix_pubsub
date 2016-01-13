defmodule Phoenix.Presence.AdapterTest do
  use ExUnit.Case, async: false
  alias Phoenix.Presence.Adapters

  defmodule StubbedNode do
    def list(), do: [node()]
  end

  @adapters %{
    Adapters.Global => [node_source: StubbedNode],
  }

  defp setup_adapter(Adapters.Global, opts) do
    {:ok, _} = Adapters.Global.start_link(opts)
    {:ok, _} = Phoenix.Presence.Tracker.start_link([pubsub_server: :pubsub])
  end

  setup_all do
    {:ok, _} = Phoenix.PubSub.PG2.start_link(:pubsub, pool_size: 1)
    :ok
  end

  ## Shared Adapter tests
  for {adapter, opts} <- @adapters do
    @adapter adapter
    @adapter_opts opts

    setup_all do
      setup_adapter(@adapter, @adapter_opts)
      :ok
    end

    test "#{@adapter} monitors node up and down events" do
      assert :ok = @adapter.monitor_nodes(self)
      simulate_nodeup(@adapter, :"some1@node")
      assert_receive {:nodeup, :"some1@node"}

      simulate_nodedown(@adapter, :"some1@node")
      assert_receive {:nodedown, :"some1@node"}
    end

    test "#{@adapter} demonitors node up and down events" do
      assert :ok = @adapter.monitor_nodes(self)
      simulate_nodeup(@adapter, :"some2@node")
      assert_receive {:nodeup, :"some2@node"}
      simulate_nodedown(@adapter, :"some2@node")
      assert_receive {:nodedown, :"some2@node"}
      assert :ok = @adapter.demonitor_nodes(self)
      simulate_nodedown(@adapter, :"some3@node")
      refute_receive {:nodedown, :"some3@node"}
    end

    test "#{@adapter} removes subscribers when they die" do
      assert subscribers(@adapter) == %{}
      subscriber = spawn fn ->
        assert :ok = @adapter.monitor_nodes(self)
        :timer.sleep(:infinity)
      end
      assert :ok = @adapter.monitor_nodes(self)
      assert Map.keys(subscribers(@adapter)) == [self, subscriber]
      Process.exit(subscriber, :kill)

      # avoids races for DOWN monitor
      simulate_nodeup(@adapter, :"some4@node")
      assert_receive {:nodeup, :"some4@node"}

      assert Map.keys(subscribers(@adapter)) == [self]
    end
  end


  ## Custom Adapter tests

  test "Global list returns active nodes" do
    assert Adapters.Global.list() == [:"nonode@nohost"]
  end

  defp simulate_nodeup(Adapters.Global = adapter, node_name) do
    send(adapter, {:nodeup, node_name})
  end

  defp simulate_nodedown(Adapters.Global = adapter, node_name) do
    send(adapter, {:nodedown, node_name})
  end

  defp subscribers(adapter),
    do: GenServer.call(adapter, :subscribers)
end
