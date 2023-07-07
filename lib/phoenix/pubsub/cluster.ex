defmodule Phoenix.PubSub.DNSCluster do
  @moduledoc false
  use GenServer
  require Logger

  @doc ~S"""
  Starts DNS based cluster discovery.

  ## Options

    * `:name` - the name of the cluster. Defaults to `DNSCluster`.
    * `:query` - the required DNS query for node discovery, for example: `myapp.internal`.

  ## Examples

      iex> start_link(name: MyApp.Cluster, query: "myapp.internal")
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    [basename, _] = String.split(to_string(node()), "@")

    state = %{
      interval: Keyword.get(opts, :interval, 5_000),
      basename: basename,
      query: Keyword.fetch!(opts, :query),
      log: Keyword.get(opts, :log, false),
      poll_timer: nil
    }

    {:ok, state, {:continue, :discover_ips}}
  end

  @impl true
  def handle_continue(:discover_ips, state) do
    {:noreply, do_discovery(state)}
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

  defp connect_new_nodes(state) do
    node_names =
      Node.list()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&String.starts_with?(&1, state.basename))

    state.query
    |> discover_ips()
    |> Enum.map(fn ip -> "#{state.basename}@#{ip}" end)
    |> Enum.filter(fn node_name -> !Enum.member?(node_names, node_name) end)
    |> Enum.each(fn new_name ->
      if Node.connect(:"#{new_name}") do
        log(state, "#{node()} connected to #{new_name}")
      end
    end)

    state
  end

  defp log(state, msg) do
    if level = state.log, do: Logger.log(level, msg)
  end

  defp schedule_next_poll(state) do
    %{state | poll_timer: Process.send_after(self(), :discover_ips, state.interval)}
  end

  def discover_ips(query) do
    [:a, :aaaa]
    |> Enum.flat_map(&:inet_res.lookup(~c"#{query}", :in, &1))
    |> Enum.map(&to_string(:inet.ntoa(&1)))
  end
end
