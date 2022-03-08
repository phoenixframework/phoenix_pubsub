defmodule Phoenix.Tracker do
  @moduledoc ~S"""
  Provides distributed presence tracking to processes.

  Tracker shards use a heartbeat protocol and CRDT to replicate presence
  information across a cluster in an eventually consistent, conflict-free
  manner. Under this design, there is no single source of truth or global
  process. Each node runs a pool of trackers and node-local changes are
  replicated across the cluster and handled locally as a diff of changes.

  ## Implementing a Tracker

  To start a tracker, first add the tracker to your supervision tree:

      children = [
        # ...
        {MyTracker, [name: MyTracker, pubsub_server: MyApp.PubSub]}
      ]

  Next, implement `MyTracker` with support for the `Phoenix.Tracker`
  behaviour callbacks. An example of a minimal tracker could include:

      defmodule MyTracker do
        use Phoenix.Tracker

        def start_link(opts) do
          opts = Keyword.merge([name: __MODULE__], opts)
          Phoenix.Tracker.start_link(__MODULE__, opts, opts)
        end

        def init(opts) do
          server = Keyword.fetch!(opts, :pubsub_server)
          {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
        end

        def handle_diff(diff, state) do
          for {topic, {joins, leaves}} <- diff do
            for {key, meta} <- joins do
              IO.puts "presence join: key \"#{key}\" with meta #{inspect meta}"
              msg = {:join, key, meta}
              Phoenix.PubSub.direct_broadcast!(state.node_name, state.pubsub_server, topic, msg)
            end
            for {key, meta} <- leaves do
              IO.puts "presence leave: key \"#{key}\" with meta #{inspect meta}"
              msg = {:leave, key, meta}
              Phoenix.PubSub.direct_broadcast!(state.node_name, state.pubsub_server, topic, msg)
            end
          end
          {:ok, state}
        end
      end

  Trackers must implement `start_link/1`, `c:init/1`, and `c:handle_diff/2`.
  The `c:init/1` callback allows the tracker to manage its own state when
  running within the `Phoenix.Tracker` server. The `handle_diff` callback
  is invoked with a diff of presence join and leave events, grouped by
  topic. As replicas heartbeat and replicate data, the local tracker state is
  merged with the remote data, and the diff is sent to the callback. The
  handler can use this information to notify subscribers of events, as
  done above.

  An optional `handle_info/2` callback may also be invoked to handle
  application specific messages within your tracker.

  ## Special Considerations

  Operations within `handle_diff/2` happen *in the tracker server's context*.
  Therefore, blocking operations should be avoided when possible, and offloaded
  to a supervised task when required. Also, a crash in the `handle_diff/2` will
  crash the tracker server, so operations that may crash the server should be
  offloaded with a `Task.Supervisor` spawned process.
  """
  use Supervisor
  require Logger
  alias Phoenix.Tracker.Shard

  @type presence :: {key :: String.t, meta :: map}
  @type topic :: String.t

  @callback init(Keyword.t) :: {:ok, state :: term} | {:error, reason :: term}
  @callback handle_diff(%{topic => {joins :: [presence], leaves :: [presence]}}, state :: term) :: {:ok, state :: term}
  @callback handle_info(message :: term, state :: term) :: {:noreply, state :: term}
  @optional_callbacks handle_info: 2

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Phoenix.Tracker

      if Module.get_attribute(__MODULE__, :doc) == nil do
        @doc """
        Returns a specification to start this module under a supervisor.

        See `Supervisor`.
        """
      end

      def child_spec(init_arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]},
          type: :supervisor
        }
      end

      defoverridable child_spec: 1
    end
  end

  ## Client

  @doc """
  Tracks a presence.

    * `server_name` - The registered name of the tracker server
    * `pid` - The Pid to track
    * `topic` - The `Phoenix.PubSub` topic for this presence
    * `key` - The key identifying this presence
    * `meta` - The map of metadata to attach to this presence

  A process may be tracked multiple times, provided the topic and key pair
  are unique for any prior calls for the given process.

  ## Examples

      iex> Phoenix.Tracker.track(MyTracker, self(), "lobby", u.id, %{stat: "away"})
      {:ok, "1WpAofWYIAA="}

      iex> Phoenix.Tracker.track(MyTracker, self(), "lobby", u.id, %{stat: "away"})
      {:error, {:already_tracked, #PID<0.56.0>, "lobby", "123"}}
  """
  @spec track(atom, pid, topic, term, map) :: {:ok, ref :: binary} | {:error, reason :: term}
  def track(tracker_name, pid, topic, key, meta) when is_pid(pid) and is_map(meta) do
    tracker_name
    |> Shard.name_for_topic(topic, pool_size(tracker_name))
    |> GenServer.call({:track, pid, topic, key, meta})
  end

  @doc """
  Untracks a presence.

    * `server_name` - The registered name of the tracker server
    * `pid` - The Pid to untrack
    * `topic` - The `Phoenix.PubSub` topic to untrack for this presence
    * `key` - The key identifying this presence

  All presences for a given Pid can be untracked by calling the
  `Phoenix.Tracker.untrack/2` signature of this function.

  ## Examples

      iex> Phoenix.Tracker.untrack(MyTracker, self(), "lobby", u.id)
      :ok
      iex> Phoenix.Tracker.untrack(MyTracker, self())
      :ok
  """
  @spec untrack(atom, pid, topic, term) :: :ok
  def untrack(tracker_name, pid, topic, key) when is_pid(pid) do
    tracker_name
    |> Shard.name_for_topic(topic, pool_size(tracker_name))
    |> GenServer.call({:untrack, pid, topic, key})
  end
  def untrack(tracker_name, pid) when is_pid(pid) do
    shard_multicall(tracker_name, {:untrack, pid})
    :ok
  end

  @doc """
  Updates a presence's metadata.

    * `server_name` - The registered name of the tracker server
    * `pid` - The Pid being tracked
    * `topic` - The `Phoenix.PubSub` topic to update for this presence
    * `key` - The key identifying this presence
    * `meta` - Either a new map of metadata to attach to this presence,
      or a function. The function will receive the current metadata as
      input and the return value will be used as the new metadata

  ## Examples

      iex> Phoenix.Tracker.update(MyTracker, self(), "lobby", u.id, %{stat: "zzz"})
      {:ok, "1WpAofWYIAA="}

      iex> Phoenix.Tracker.update(MyTracker, self(), "lobby", u.id, fn meta -> Map.put(meta, :away, true) end)
      {:ok, "1WpAofWYIAA="}
  """
  @spec update(atom, pid, topic, term, map | (map -> map)) :: {:ok, ref :: binary} | {:error, reason :: term}
  def update(tracker_name, pid, topic, key, meta) when is_pid(pid) and (is_map(meta) or is_function(meta)) do
    tracker_name
    |> Shard.name_for_topic(topic, pool_size(tracker_name))
    |> GenServer.call({:update, pid, topic, key, meta})
  end

  @doc """
  Lists all presences tracked under a given topic.

    * `server_name` - The registered name of the tracker server
    * `topic` - The `Phoenix.PubSub` topic

  Returns a lists of presences in key/metadata tuple pairs.

  ## Examples

      iex> Phoenix.Tracker.list(MyTracker, "lobby")
      [{123, %{name: "user 123"}}, {456, %{name: "user 456"}}]
  """
  @spec list(atom, topic) :: [presence]
  def list(tracker_name, topic) do
    tracker_name
    |> Shard.name_for_topic(topic, pool_size(tracker_name))
    |> Phoenix.Tracker.Shard.list(topic)
  end

  @doc """
  Gets presences tracked under a given topic and key pair.

    * `server_name` - The registered name of the tracker server
    * `topic` - The `Phoenix.PubSub` topic
    * `key` - The key of the presence

  Returns a lists of presence metadata.

  ## Examples

      iex> Phoenix.Tracker.get_by_key(MyTracker, "lobby", "user1")
      [{#PID<0.88.0>, %{name: "User 1"}, {#PID<0.89.0>, %{name: "User 1"}]
  """
  @spec get_by_key(atom, topic, term) :: [presence]
  def get_by_key(tracker_name, topic, key) do
    tracker_name
    |> Shard.name_for_topic(topic, pool_size(tracker_name))
    |> Phoenix.Tracker.Shard.get_by_key(topic, key)
  end

  @doc """
  Gracefully shuts down by broadcasting permdown to all replicas.

  ## Examples

      iex> Phoenix.Tracker.graceful_permdown(MyTracker)
      :ok
  """
  @spec graceful_permdown(atom) :: :ok
  def graceful_permdown(tracker_name) do
    shard_multicall(tracker_name, :graceful_permdown)
    Supervisor.stop(tracker_name)
  end

  @doc """
  Starts a tracker pool.

    * `tracker` - The tracker module implementing the `Phoenix.Tracker` behaviour
    * `tracker_arg` - The argument to pass to the tracker handler `c:init/1`
    * `pool_opts` - The list of options used to construct the shard pool

  ## Required `pool_opts`:

    * `:name` - The name of the server, such as: `MyApp.Tracker`
      This will also form the common prefix for all shard names
    * `:pubsub_server` - The name of the PubSub server, such as: `MyApp.PubSub`

  ## Optional `pool_opts`:

    * `:broadcast_period` - The interval in milliseconds to send delta broadcasts
      across the cluster. Default `1500`
    * `:max_silent_periods` - The max integer of broadcast periods for which no
      delta broadcasts have been sent. Default `10` (15s heartbeat)
    * `:down_period` - The interval in milliseconds to flag a replica
      as temporarily down. Default `broadcast_period * max_silent_periods * 2`
      (30s down detection). Note: This must be at least 2x the `broadcast_period`.
    * `:permdown_period` - The interval in milliseconds to flag a replica
      as permanently down, and discard its state.
      Note: This must be at least greater than the `down_period`.
      Default `1_200_000` (20 minutes)
    * `:clock_sample_periods` - The numbers of heartbeat windows to sample
      remote clocks before collapsing and requesting transfer. Default `2`
    * `:max_delta_sizes` - The list of delta generation sizes to keep before
      falling back to sending entire state. Defaults `[100, 1000, 10_000]`.
    * `:log_level` - The log level to log events, defaults `:debug` and can be
      disabled with `false`
    * `:pool_size` - The number of tracker shards to launch. Default `1`
  """
  def start_link(tracker, tracker_arg, pool_opts) do
    name = Keyword.fetch!(pool_opts, :name)
    Supervisor.start_link(__MODULE__, [tracker, tracker_arg, pool_opts, name], name: name)
  end

  @impl true
  def init([tracker, tracker_opts, opts, name]) do
    pool_size = Keyword.get(opts, :pool_size, 1)
    ^name = :ets.new(name, [:set, :named_table, read_concurrency: true])
    true = :ets.insert(name, {:pool_size, pool_size})

    shards =
      for n <- 0..(pool_size - 1) do
        shard_name = Shard.name_for_number(name, n)
        shard_opts = Keyword.put(opts, :shard_number, n)

        %{
          id: shard_name,
          start: {Phoenix.Tracker.Shard, :start_link, [tracker, tracker_opts, shard_opts]}
        }
      end

    opts = [
      strategy: :one_for_one,
      max_restarts: pool_size * 2,
      max_seconds: 1
    ]

    Supervisor.init(shards, opts)
  end

  defp pool_size(tracker_name) do
    [{:pool_size, size}] = :ets.lookup(tracker_name, :pool_size)
    size
  end

  defp shard_multicall(tracker_name, message) do
    for shard_number <- 0..(pool_size(tracker_name) - 1) do
      tracker_name
      |> Shard.name_for_number(shard_number)
      |> GenServer.call(message)
    end
  end
end
