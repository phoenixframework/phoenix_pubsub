defmodule Phoenix.PubSub.DNSCluster do
  @moduledoc false
  use GenServer
  require Logger

  @doc ~S"""
  Starts DNS based cluster discovery.

  ## Options

    * `:name` - the required name of the cluster
    * `:node` - the node name of the current node, for example: `myapp@127.0.0.1`.
      Environment variable replacement is supported, for example: `myapp@${PRIVATE_IP}`.
    * `:query` - the required DNS query for node discovery, for example: `myapp.internal`.

  ## Examples

      iex> start_link(
        name: MyApp.Cluster,
        node: "${IMAGE_REF}@${PRIVATE_IP}",
        query: "myapp.internal",
      )
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {basename, ip} = parse_node_name(Keyword.fetch!(opts, :node))
    make_dist_node!(basename, ip)

    state = %{
      interval: Keyword.get(opts, :interval, 5_000),
      basename: basename,
      query: Keyword.fetch!(opts, :query),
      log: Keyword.get(opts, :log, false),
      poll_timer: nil
    }

    {:ok, state, {:continue, :discover_ips}}
  end

  defp make_dist_node!(basename, ip) do
    node_name = :"#{basename}@#{ip}"

    if node_name == node() do
      :ok
    else
      case :net_kernel.start(node_name, %{name_domain: :longnames}) do
        {:ok, _pid} -> :ok
        {:error, reason} -> raise_invalid_dist(node_name, reason)
      end
    end
  end

  defp raise_invalid_dist(node_name, reason) do
    raise """
    Failed to put node #{node()} in distributed mode under name #{node_name}:

        #{inspect(reason)}
    """
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
  end

  defp log(state, msg) do
    if level = state.log, do: Logger.log(level, msg)
  end

  defp schedule_next_poll(state) do
    %{state | poll_timer: Process.send_after(self(), :discover_ips, state.interval)}
  end

  def parse_node_name(node_name) when is_binary(node_name) do
    replaced =
      Regex.replace(~r/\$\{([A-Za-z0-9_]+)\}/, node_name, fn _, var ->
        System.fetch_env!(String.trim(var, "{}"))
      end)

    [basename, ip] = String.split(replaced, "@")
    sanitized_base = String.replace(basename, ~r/[^a-zA-Z0-9-]/, "-")

    {sanitized_base, ip}
  end

  def discover_ips(query) do
    [:a, :aaaa]
    |> Enum.flat_map(&:inet_res.lookup(~c"#{query}", :in, &1))
    |> Enum.map(&to_string(:inet.ntoa(&1)))
  end
end
