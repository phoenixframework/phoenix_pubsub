defmodule Phoenix.PubSub.DNSClusterTest do
  use Phoenix.PubSub.NodeCase, async: false

  alias Phoenix.PubSub.DNSCluster

  @ips %{
    already_known: 'fdaa:0:36c9:a7b:db:400e:1352:1',
    new: 'fdaa:0:36c9:a7b:db:400e:1352:2',
    no_connect_diff_base: 'fdaa:0:36c9:a7b:db:400e:1352:3',
  }

  @new_node :"app@#{@ips.new}"
  def connect_node(@new_node) do
     send(__MODULE__, {:try_connect, @new_node})
     true
  end

  @no_connect_node :"app@#{@ips.no_connect_diff_base}"
  def connect_node(@no_connect_node) do
     false
  end

  def basename(_node_name), do: "app"

  def lookup(_query, _type) do
    {:ok, dns_ip1} = :inet.parse_address(@ips.already_known)
    {:ok, dns_ip2} = :inet.parse_address(@ips.new)
    {:ok, dns_ip3} = :inet.parse_address(@ips.no_connect_diff_base)

    [dns_ip1, dns_ip2, dns_ip3]
  end

  def list_nodes do
    [:"app@#{@ips.already_known}"]
  end

  defp wait_for_node_discovery(cluster) do
    :sys.get_state(cluster)
    :ok
  end

  setup config do
    Process.register(self(), __MODULE__)
    {:ok, cluster} =
      start_supervised(
        {DNSCluster,
         name: config.test, query: "app.internal", resolver: __MODULE__}
      )

    wait_for_node_discovery(cluster)

    {:ok, cluster: cluster}
  end

  test "discovers nodes" do
    new_node = :"app@#{@ips.new}"
    no_connect_node = :"app@#{@ips.no_connect_diff_base}"
    assert_receive {:try_connect, ^new_node}
    refute_receive {:try_connect, ^no_connect_node}
    refute_receive _
  end
end
