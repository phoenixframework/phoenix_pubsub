defmodule Phoenix.PubSub do
  @moduledoc """
  Realtime Publisher/Subscriber service.

  ## Getting started

  You start Phoenix.PubSub directly in your supervision
  tree:

      {Phoenix.PubSub, name: :my_pubsub}

  You can now use the functions in this module to subscribe
  and broadcast messages:

      iex> alias Phoenix.PubSub
      iex> PubSub.subscribe(:my_pubsub, "user:123")
      :ok
      iex> Process.info(self(), :messages)
      {:messages, []}
      iex> PubSub.broadcast(:my_pubsub, "user:123", {:user_update, %{id: 123, name: "Shane"}})
      :ok
      iex> Process.info(self(), :messages)
      {:messages, [{:user_update, %{id: 123, name: "Shane"}}]}

  ## Adapters

  Phoenix PubSub was designed to be flexible and support
  multiple backends. There are two officially supported
  backends:

    * `Phoenix.PubSub.PG2` - the default adapter that ships
      as part of Phoenix.PubSub. It uses Distributed Elixir,
      directly exchanging notifications between servers.
      It supports a `:pool_size` option to be given alongside
      the name, defaults to `1`. Note the `:pool_size` must
      be the same throughout the cluster, therefore don't
      configure the pool size based on `System.schedulers_online/0`,
      especially if you are using machines with different specs.

    * `Phoenix.PubSub.Redis` - uses Redis to exchange data between
      servers. It requires the `:phoenix_pubsub_redis` dependency.

  See `Phoenix.PubSub.Adapter` to implement a custom adapter.

  ## Custom dispatching

  Phoenix.PubSub allows developers to perform custom dispatching
  by passing a `dispatcher` module which is responsible for local
  message deliveries.

  The dispatcher must be available on all nodes running the PubSub
  system. The `dispatch/3` function of the given module will be
  invoked with the subscriptions entries, the broadcaster identifier
  (either a pid or `:none`), and the message to broadcast.

  You may want to use the dispatcher to perform special delivery for
  certain subscriptions. This can be done by passing the :metadata
  option during subscriptions. For instance, Phoenix Channels use a
  custom `value` to provide "fastlaning", allowing messages broadcast
  to thousands or even millions of users to be encoded once and written
  directly to sockets instead of being encoded per channel.

  ## Safe pool size migration (when using `Phoenix.PubSub.PG2` adapter)

  When you need to change the pool size in a running cluster,
  you can use the `broadcast_pool_size` option to ensure no
  messages are lost during deployment. This is particularly
  important when increasing the pool size.

  Here's how to safely increase the pool size from 1 to 2:

  1. Initial state - Current configuration with `pool_size: 1`:
  ```
  {Phoenix.PubSub, name: :my_pubsub, pool_size: 1}
  ```

  ```mermaid
  graph TD
      subgraph "Initial State"
          subgraph "Node 1"
              A1[Shard 1<br/>Broadcast & Receive]
          end
          subgraph "Node 2"
              B1[Shard 1<br/>Broadcast & Receive]
          end
          A1 <--> B1
      end
  ```

  2. First deployment - Set the new pool size but keep broadcasting on the old size:
  ```
  {Phoenix.PubSub, name: :my_pubsub, pool_size: 2, broadcast_pool_size: 1}
  ```

  ```mermaid
  graph TD
      subgraph "First Deployment"
          subgraph "Node 1"
              A1[Shard 1<br/>Broadcast & Receive]
              A2[Shard 2<br/>Broadcast & Receive]
          end
          subgraph "Node 2"
              B1[Shard 1<br/>Broadcast & Receive]
              B2[Shard 2<br/>Receive Only]
          end
          A1 <--> B1
          A2 --> B2
      end
  ```

  3. Final deployment - All nodes running with new pool size:
  ```
  {Phoenix.PubSub, name: :my_pubsub, pool_size: 2}
  ```

  ```mermaid
  graph TD
      subgraph "Final State"
          subgraph "Node 1"
              A1[Shard 1<br/>Broadcast & Receive]
              A2[Shard 2<br/>Broadcast & Receive]
          end
          subgraph "Node 2"
              B1[Shard 1<br/>Broadcast & Receive]
              B2[Shard 2<br/>Broadcast & Receive]
          end
          A1 <--> B1
          A2 <--> B2
      end
  ```

  This two-step process ensures that:
  - All nodes can receive messages from both old and new pool sizes
  - No messages are lost during the transition
  - The cluster remains fully functional throughout the deployment

  To decrease the pool size, follow the same process in reverse order.

  """

  @type node_name :: atom | binary
  @type t :: atom
  @type topic :: binary
  @type message :: term
  @type dispatcher :: module

  defmodule BroadcastError do
    defexception [:message]

    def exception(msg) do
      %BroadcastError{message: "broadcast failed with #{inspect(msg)}"}
    end
  end

  @doc """
  Returns a child specification for pubsub with the given `options`.

  The `:name` is required as part of `options`. The remaining options
  are described below.

  ## Options

    * `:name` - the name of the pubsub to be started
    * `:adapter` - the adapter to use (defaults to `Phoenix.PubSub.PG2`)
    * `:pool_size` - number of pubsub partitions to launch
      (defaults to one partition for every 4 cores)
    * `:registry_size` - number of `Registry` partitions to launch
      (defaults to `:pool_size`). This controls the number of Registry partitions
      used for storing subscriptions and can be tuned independently from `:pool_size`
      for better performance characteristics.
    * `:broadcast_pool_size` - number of pubsub partitions used for broadcasting messages
      (defaults to `:pool_size`). This option is used during pool size migrations to ensure
      no messages are lost. See the "Safe Pool Size Migration" section in the module documentation.

  """
  @spec child_spec(keyword) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: Phoenix.PubSub.Supervisor

  @doc """
  Subscribes the caller to the PubSub adapter's topic.

    * `pubsub` - The name of the pubsub system
    * `topic` - The topic to subscribe to, for example: `"users:123"`
    * `opts` - The optional list of options. See below.

  ## Duplicate Subscriptions

  Callers should only subscribe to a given topic a single time.
  Duplicate subscriptions for a Pid/topic pair are allowed and
  will cause duplicate events to be sent; however, when using
  `Phoenix.PubSub.unsubscribe/2`, all duplicate subscriptions
  will be dropped.

  ## Options

    * `:metadata` - provides metadata to be attached to this
      subscription. The metadata can be used by custom
      dispatching mechanisms. See the "Custom dispatching"
      section in the module documentation

  """
  @spec subscribe(t, topic, keyword) :: :ok | {:error, term}
  def subscribe(pubsub, topic, opts \\ [])
      when is_atom(pubsub) and is_binary(topic) and is_list(opts) do
    case Registry.register(pubsub, topic, opts[:metadata]) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Unsubscribes the caller from the PubSub adapter's topic.
  """
  @spec unsubscribe(t, topic) :: :ok
  def unsubscribe(pubsub, topic) when is_atom(pubsub) and is_binary(topic) do
    Registry.unregister(pubsub, topic)
  end

  @doc """
  Broadcasts message on given topic across the whole cluster.

    * `pubsub` - The name of the pubsub system
    * `topic` - The topic to broadcast to, ie: `"users:123"`
    * `message` - The payload of the broadcast

  A custom dispatcher may also be given as a fourth, optional argument.
  See the "Custom dispatching" section in the module documentation.
  """
  @spec broadcast(t, topic, message, dispatcher) :: :ok | {:error, term}
  def broadcast(pubsub, topic, message, dispatcher \\ __MODULE__)
      when is_atom(pubsub) and is_binary(topic) and is_atom(dispatcher) do
    {:ok, {adapter, name}} = Registry.meta(pubsub, :pubsub)

    with :ok <- adapter.broadcast(name, topic, message, dispatcher) do
      dispatch(pubsub, :none, topic, message, dispatcher)
    end
  end

  @doc """
  Broadcasts message on given topic from the given process across the whole cluster.

    * `pubsub` - The name of the pubsub system
    * `from` - The pid that will send the message
    * `topic` - The topic to broadcast to, ie: `"users:123"`
    * `message` - The payload of the broadcast

  The default dispatcher will broadcast the message to all subscribers except for the
  process that initiated the broadcast.

  A custom dispatcher may also be given as a fifth, optional argument.
  See the "Custom dispatching" section in the module documentation.
  """
  @spec broadcast_from(t, pid, topic, message, dispatcher) :: :ok | {:error, term}
  def broadcast_from(pubsub, from, topic, message, dispatcher \\ __MODULE__)
      when is_atom(pubsub) and is_pid(from) and is_binary(topic) and is_atom(dispatcher) do
    {:ok, {adapter, name}} = Registry.meta(pubsub, :pubsub)

    with :ok <- adapter.broadcast(name, topic, message, dispatcher) do
      dispatch(pubsub, from, topic, message, dispatcher)
    end
  end

  @doc """
  Broadcasts message on given topic only for the current node.

    * `pubsub` - The name of the pubsub system
    * `topic` - The topic to broadcast to, ie: `"users:123"`
    * `message` - The payload of the broadcast

  A custom dispatcher may also be given as a fourth, optional argument.
  See the "Custom dispatching" section in the module documentation.
  """
  @spec local_broadcast(t, topic, message, dispatcher) :: :ok
  def local_broadcast(pubsub, topic, message, dispatcher \\ __MODULE__)
      when is_atom(pubsub) and is_binary(topic) and is_atom(dispatcher) do
    dispatch(pubsub, :none, topic, message, dispatcher)
  end

  @doc """
  Broadcasts message on given topic from a given process only for the current node.

    * `pubsub` - The name of the pubsub system
    * `from` - The pid that will send the message
    * `topic` - The topic to broadcast to, ie: `"users:123"`
    * `message` - The payload of the broadcast

  The default dispatcher will broadcast the message to all subscribers except for the
  process that initiated the broadcast.

  A custom dispatcher may also be given as a fifth, optional argument.
  See the "Custom dispatching" section in the module documentation.
  """
  @spec local_broadcast_from(t, pid, topic, message, dispatcher) :: :ok
  def local_broadcast_from(pubsub, from, topic, message, dispatcher \\ __MODULE__)
      when is_atom(pubsub) and is_pid(from) and is_binary(topic) and is_atom(dispatcher) do
    dispatch(pubsub, from, topic, message, dispatcher)
  end

  @doc """
  Broadcasts message on given topic to a given node.

    * `node_name` - The target node name
    * `pubsub` - The name of the pubsub system
    * `topic` - The topic to broadcast to, ie: `"users:123"`
    * `message` - The payload of the broadcast

  **DO NOT** use this function if you wish to broadcast to the current
  node, as it is always serialized, use `local_broadcast/4` instead.

  A custom dispatcher may also be given as a fifth, optional argument.
  See the "Custom dispatching" section in the module documentation.
  """
  @spec direct_broadcast(node_name, t, topic, message, dispatcher) :: :ok | {:error, term}
  def direct_broadcast(node_name, pubsub, topic, message, dispatcher \\ __MODULE__)
      when is_atom(pubsub) and is_binary(topic) and is_atom(dispatcher) do
    {:ok, {adapter, name}} = Registry.meta(pubsub, :pubsub)
    adapter.direct_broadcast(name, node_name, topic, message, dispatcher)
  end

  @doc """
  Raising version of `broadcast/4`.
  """
  @spec broadcast!(t, topic, message, dispatcher) :: :ok
  def broadcast!(pubsub, topic, message, dispatcher \\ __MODULE__) do
    case broadcast(pubsub, topic, message, dispatcher) do
      :ok -> :ok
      {:error, error} -> raise BroadcastError, "broadcast failed: #{inspect(error)}"
    end
  end

  @doc """
  Raising version of `broadcast_from/5`.
  """
  @spec broadcast_from!(t, pid, topic, message, dispatcher) :: :ok
  def broadcast_from!(pubsub, from, topic, message, dispatcher \\ __MODULE__) do
    case broadcast_from(pubsub, from, topic, message, dispatcher) do
      :ok -> :ok
      {:error, error} -> raise BroadcastError, "broadcast failed: #{inspect(error)}"
    end
  end

  @doc """
  Raising version of `direct_broadcast/5`.
  """
  @spec direct_broadcast!(node_name, t, topic, message, dispatcher) :: :ok
  def direct_broadcast!(node_name, pubsub, topic, message, dispatcher \\ __MODULE__) do
    case direct_broadcast(node_name, pubsub, topic, message, dispatcher) do
      :ok -> :ok
      {:error, error} -> raise BroadcastError, "broadcast failed: #{inspect(error)}"
    end
  end

  @doc """
  Returns the node name of the PubSub server.
  """
  @spec node_name(t) :: node_name
  def node_name(pubsub) do
    {:ok, {adapter, name}} = Registry.meta(pubsub, :pubsub)
    adapter.node_name(name)
  end

  ## Dispatch callback

  @doc false
  def dispatch(entries, :none, message) do
    for {pid, _} <- entries do
      send(pid, message)
    end

    :ok
  end

  def dispatch(entries, from, message) do
    for {pid, _} <- entries, pid != from do
      send(pid, message)
    end

    :ok
  end

  defp dispatch(pubsub, from, topic, message, dispatcher) do
    Registry.dispatch(pubsub, topic, {dispatcher, :dispatch, [from, message]})
    :ok
  end
end
