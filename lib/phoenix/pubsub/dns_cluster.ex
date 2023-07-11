defmodule Phoenix.PubSub.DNSCluster do
  @moduledoc """
  Simple DNS based cluster discovery.

  A DNS query is made every `:interval` milliseconds to discover new ips.
  Nodes will only be joined if their node basename matches the basename of the
  current node. For example if `node()` is `myapp-123@fdaa:1:36c9:a7b:198:c4b1:73c6:1`,
  a `Node.connect/1` attempt will be made against every IP returned by the DNS query,
  but will only be successful if there is a node running on the remote host with the same
  basename, for example `myapp-123@fdaa:1:36c9:a7b:198:c4b1:73c6:2`. Nodes running on
  remote hosts, but with different basenames will fail to connect and will be ignored.

  ## Examples

  To start in your supervision tree, add the child:

      children = [
        ...,
        {Phoenix.PubSub.DNSCluster, name: MyApp.Cluster, query: "myapp.internal"}
      ]

  See the `start_link/1` docs for all available options.

  If you require more advanced clustering options and strategies, see the
  [libcluster](https://hexdocs.pm/libcluster) library.
  """
  use GenServer
  require Logger

  defmodule Resolver do
    @moduledoc false
    def basename(node_name) when is_atom(node_name) do
      [basename, _] = String.split(to_string(node_name), "@")
      basename
    end

    def connect_node(node_name) when is_atom(node_name), do: Node.connect(node_name)

    def list_nodes, do: Node.list(:visible)

    def lookup(query, type) when is_binary(query) and type in [:a, :aaaa] do
      :inet_res.lookup(~c"#{query}", :in, type)
    end
  end

  @doc ~S"""
  Starts DNS based cluster discovery.

  ## Options

    * `:name` - the name of the cluster. Defaults to `Phoenix.PubSub.DNSCluster`.
    * `:query` - the required DNS query for node discovery, for example: `myapp.internal`.
    * `:interval` - the millisec interval between DNS queries. Defaults to `5000`.
    * `:connect_timeout` - the millisec timeout to allow all discovered nodes to connect.
      Defaults to `10_000`.

  ## Examples

      iex> start_link(name: MyApp.Cluster, query: "myapp.internal")
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    resolver = Keyword.get(opts, :resolver, Resolver)

    # discover nodes on init so we're connected before downstream children start
    state =
      do_discovery(%{
        interval: Keyword.get(opts, :interval, 5_000),
        basename: resolver.basename(node()),
        query: Keyword.fetch!(opts, :query),
        log: Keyword.get(opts, :log, false),
        poll_timer: nil,
        connect_timeout: Keyword.get(opts, :connect_timeout, 15_000),
        resolver: resolver
      })

    {:ok, state}
  end

  @impl true
  def handle_info(:discover_ips, state) do
    {:noreply, do_discovery(state)}
  end

  defp do_discovery(state) do
    state
    |> connect_new_nodes()
    |> schedule_next_poll()
  end

  defp connect_new_nodes(%{resolver: resolver, connect_timeout: timeout} = state) do
    node_names = for name <- resolver.list_nodes(), into: MapSet.new(), do: to_string(name)

    task =
      Task.async(fn ->
        ips = discover_ips(state)

        ips
        |> Enum.map(fn ip -> "#{state.basename}@#{ip}" end)
        |> Enum.filter(fn node_name -> !Enum.member?(node_names, node_name) end)
        |> Task.async_stream(
          fn new_name ->
            if resolver.connect_node(:"#{new_name}") do
              log(state, "#{node()} connected to #{new_name}")
            end
          end,
          max_concurrency: length(ips),
          timeout: timeout
        )
        |> Enum.to_list()
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, _result} -> :ok
      nil -> Logger.warn("Failed to connect new nodes in within #{timeout}ms")
    end

    state
  end

  defp log(state, msg) do
    if level = state.log, do: Logger.log(level, msg)
  end

  defp schedule_next_poll(state) do
    %{state | poll_timer: Process.send_after(self(), :discover_ips, state.interval)}
  end

  defp discover_ips(%{resolver: resolver, query: query}) do
    [:a, :aaaa]
    |> Enum.flat_map(&resolver.lookup(query, &1))
    |> Enum.uniq()
    |> Enum.map(&to_string(:inet.ntoa(&1)))
  end
end
