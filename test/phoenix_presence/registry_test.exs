defmodule Phoenix.Presence.RegistryTest do
  use ExUnit.Case, async: false
  alias Phoenix.Presence.Registry

  setup_all do
    {:ok, _} = Phoenix.Presence.Adapters.Global.start_link([])
    {:ok, _} = Phoenix.PubSub.PG2.start_link(:reg_pub, pool_size: 1)
    {:ok, _} = Phoenix.Presence.Tracker.start_link([pubsub_server: :reg_pub])
    :ok
  end

  test "find returns nil when no server exists for topic" do
    assert Registry.find(:reg_pub, "not_tracked") == nil
  end

  test "find returns pid when server exists for topic" do
    assert Registry.find(:reg_pub, "foo") == nil
    {:ok, pid} = Registry.find_or_spawn(:reg_pub, "foo")

    assert Registry.find(:reg_pub, "foo") == pid
    assert Registry.find(:reg_pub, "foo2") == nil
  end

  test "registry drops entry when process dies" do
    {:ok, pid} = Registry.find_or_spawn(:reg_pub, "herethengone")
    Process.monitor(pid)
    assert Registry.find(:reg_pub, "herethengone") == pid
    Process.exit(pid, :kill)
    assert_receive {:DOWN, _ref, :process, ^pid, _}

    Registry.find_or_spawn(:reg_pub, "sync") # avoid races
    assert Registry.dirty_find(:reg_pub, "herethengone") == nil
  end
end
