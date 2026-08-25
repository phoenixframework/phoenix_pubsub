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

  ## Tagged subscriptions

  A process may subscribe to the same topic more than once. By default
  every subscription delivers the same message, which leaves the
  subscriber unable to tell them apart.

  Passing a `:tag` makes each subscription self-describing. Messages for
  a tagged subscription are delivered wrapped as `{tag, message}`:

      tag = make_ref()
      Phoenix.PubSub.subscribe(:my_pubsub, "user:123", tag: tag)
      Phoenix.PubSub.broadcast(:my_pubsub, "user:123", :ping)
      #=> receives {tag, :ping}

  Tagged and untagged subscriptions coexist on the same topic, each
  receiving its own message:

      Phoenix.PubSub.subscribe(:my_pubsub, "user:123")
      Phoenix.PubSub.subscribe(:my_pubsub, "user:123", tag: tag)
      Phoenix.PubSub.broadcast(:my_pubsub, "user:123", :ping)
      #=> receives both :ping and {tag, :ping}

  Any term may be used as a tag, but it must be unique within the
  subscribing process for `unsubscribe/3` to remove the right
  subscription, so `make_ref/0` is usually the best choice.
  `unsubscribe/3` drops a single tagged subscription, while
  `unsubscribe/2` drops every subscription the caller holds on the
  topic, tagged or not.

  Tags are stored as subscription metadata and are therefore local to
  the subscribing node. They are never sent across the cluster.

  Tags are applied by the default dispatcher. A custom dispatcher must
  call `tag_message/2` in its ordinary delivery branch to honor them,
  otherwise messages reach tagged subscribers unwrapped. See
  `tag_message/2` for an example.

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
  @type tag :: term

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
    * `:dispatcher` - the default dispatcher module for broadcasts
      (defaults to `Phoenix.PubSub`). Can be overridden per-call by
      passing a dispatcher to `broadcast/4` and friends.
    * `:group_by` - controls how the underlying `Registry` partitions
      subscriptions, either `:pid` or `:key` (defaults to `:pid`). With
      `:pid`, entries are grouped by subscriber pid — best when topics
      have many subscribers each. With `:key`, entries are grouped by
      topic so key-based lookups touch a single partition — best when
      there are many topics with few subscribers each. `:key` requires
      Elixir v1.19 or later. See `Registry.start_link/1` for the
      underlying trade-offs.

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

  If you do want several independent subscriptions to the same
  topic within one process, give each of them a `:tag` so that
  they can be told apart and unsubscribed individually.

  ## Options

    * `:tag` - delivers messages for this subscription wrapped as
      `{tag, message}` instead of `message`. See the "Tagged
      subscriptions" section in the module documentation

    * `:metadata` - provides metadata to be attached to this
      subscription. The metadata can be used by custom
      dispatching mechanisms. See the "Custom dispatching"
      section in the module documentation

  """
  @spec subscribe(t, topic, keyword) :: :ok | {:error, term}
  def subscribe(pubsub, topic, opts \\ [])
      when is_atom(pubsub) and is_binary(topic) and is_list(opts) do
    case Registry.register(pubsub, topic, subscription_value(opts)) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp subscription_value(opts) do
    case {Keyword.fetch(opts, :tag), Keyword.fetch(opts, :metadata)} do
      {:error, :error} ->
        nil

      {:error, {:ok, metadata}} ->
        metadata

      {{:ok, tag}, :error} ->
        {__MODULE__, tag}

      {{:ok, _}, {:ok, _}} ->
        raise ArgumentError, """
        cannot pass both :tag and :metadata to Phoenix.PubSub.subscribe/3

        :tag is applied by the default dispatcher, while :metadata is meant \
        for custom dispatchers. If you need both, pass :metadata and have \
        your dispatcher call Phoenix.PubSub.tag_message/2.
        """
    end
  end

  @doc """
  Unsubscribes the caller from the PubSub adapter's topic.

  Without options, every subscription the caller holds on `topic` is
  dropped, including tagged ones.

  ## Options

    * `:tag` - drops only the subscription made with the given tag,
      leaving the caller's other subscriptions to `topic` in place.
      See the "Tagged subscriptions" section in the module documentation

  ## Examples

      iex> tag = make_ref()
      iex> PubSub.subscribe(:my_pubsub, "user:123", tag: tag)
      :ok
      iex> PubSub.subscribe(:my_pubsub, "user:123")
      :ok
      iex> PubSub.unsubscribe(:my_pubsub, "user:123", tag: tag)
      :ok
      # Only the tagged subscription is removed, the untagged one remains

  """
  @spec unsubscribe(t, topic, keyword) :: :ok
  def unsubscribe(pubsub, topic, opts \\ [])
      when is_atom(pubsub) and is_binary(topic) and is_list(opts) do
    case Keyword.fetch(opts, :tag) do
      {:ok, tag} ->
        # The tag is compared in a guard rather than being placed in the match
        # pattern directly, so that tags which happen to be match spec atoms,
        # such as :_ or :"$1", are treated as ordinary terms.
        Registry.unregister_match(pubsub, topic, {__MODULE__, :"$1"}, [
          {:==, :"$1", {:const, tag}}
        ])

      :error ->
        Registry.unregister(pubsub, topic)
    end
  end

  @doc """
  Unsubscribes the caller from the PubSub adapter's topic taking the metadata into consideration.

  Unlike `unsubscribe/2`, this function matches on the metadata provided as an option when subscribed.
  This is useful when you have multiple subscriptions for the same topic with different metadata.

  ## Example

      iex> PubSub.subscribe_match(:my_pubsub, "users:123", metadata: :fast)
      :ok
      iex> PubSub.subscribe_match(:my_pubsub, "users:123", metadata: :slow)
      :ok
      iex> PubSub.unsubscribe_match(:my_pubsub, "users:123", :fast)
      :ok
      # Only the :fast subscription is removed, :slow remains active

  """
  @spec unsubscribe_match(t, topic, term) :: :ok
  def unsubscribe_match(pubsub, topic, metadata) when is_atom(pubsub) and is_binary(topic) do
    Registry.unregister_match(pubsub, topic, metadata)
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
  def broadcast(pubsub, topic, message, dispatcher \\ nil)
      when is_atom(pubsub) and is_binary(topic) and is_atom(dispatcher) do
    {:ok, {adapter, name, default_dispatcher}} = Registry.meta(pubsub, :pubsub)
    dispatcher = dispatcher || default_dispatcher

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
  def broadcast_from(pubsub, from, topic, message, dispatcher \\ nil)
      when is_atom(pubsub) and is_pid(from) and is_binary(topic) and is_atom(dispatcher) do
    {:ok, {adapter, name, default_dispatcher}} = Registry.meta(pubsub, :pubsub)
    dispatcher = dispatcher || default_dispatcher

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
  def local_broadcast(pubsub, topic, message, dispatcher \\ nil)
      when is_atom(pubsub) and is_binary(topic) and is_atom(dispatcher) do
    {:ok, {_adapter, _name, default_dispatcher}} = Registry.meta(pubsub, :pubsub)
    dispatch(pubsub, :none, topic, message, dispatcher || default_dispatcher)
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
  def local_broadcast_from(pubsub, from, topic, message, dispatcher \\ nil)
      when is_atom(pubsub) and is_pid(from) and is_binary(topic) and is_atom(dispatcher) do
    {:ok, {_adapter, _name, default_dispatcher}} = Registry.meta(pubsub, :pubsub)
    dispatch(pubsub, from, topic, message, dispatcher || default_dispatcher)
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
  def direct_broadcast(node_name, pubsub, topic, message, dispatcher \\ nil)
      when is_atom(pubsub) and is_binary(topic) and is_atom(dispatcher) do
    {:ok, {adapter, name, default_dispatcher}} = Registry.meta(pubsub, :pubsub)
    adapter.direct_broadcast(name, node_name, topic, message, dispatcher || default_dispatcher)
  end

  @doc """
  Raising version of `broadcast/4`.
  """
  @spec broadcast!(t, topic, message, dispatcher) :: :ok
  def broadcast!(pubsub, topic, message, dispatcher \\ nil) do
    case broadcast(pubsub, topic, message, dispatcher) do
      :ok -> :ok
      {:error, error} -> raise BroadcastError, "broadcast failed: #{inspect(error)}"
    end
  end

  @doc """
  Raising version of `broadcast_from/5`.
  """
  @spec broadcast_from!(t, pid, topic, message, dispatcher) :: :ok
  def broadcast_from!(pubsub, from, topic, message, dispatcher \\ nil) do
    case broadcast_from(pubsub, from, topic, message, dispatcher) do
      :ok -> :ok
      {:error, error} -> raise BroadcastError, "broadcast failed: #{inspect(error)}"
    end
  end

  @doc """
  Raising version of `direct_broadcast/5`.
  """
  @spec direct_broadcast!(node_name, t, topic, message, dispatcher) :: :ok
  def direct_broadcast!(node_name, pubsub, topic, message, dispatcher \\ nil) do
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
    {:ok, {adapter, name, _dispatcher}} = Registry.meta(pubsub, :pubsub)
    adapter.node_name(name)
  end

  @doc """
  Applies a subscription's tag to `message`.

  Returns `{tag, message}` when the subscription was made with a `:tag`
  and `message` unchanged otherwise.

  The default dispatcher calls this for every entry. A custom dispatcher
  should call it wherever it would otherwise have written
  `send(pid, message)`, which is the branch tagged subscriptions always
  take: because `:tag` and `:metadata` are mutually exclusive, a tagged
  subscription carries no custom metadata and therefore never matches a
  dispatcher's own metadata shapes.

  ## Examples

  A dispatcher with its own metadata protocol, here writing directly to a
  transport process, plus the ordinary delivery branch where tags apply:

      defmodule MyApp.Dispatcher do
        def dispatch(entries, from, message) do
          for {pid, metadata} <- entries, pid != from do
            case metadata do
              {:fastlane, transport_pid, serializer} ->
                send(transport_pid, serializer.encode!(message))

              metadata ->
                send(pid, Phoenix.PubSub.tag_message(metadata, message))
            end
          end

          :ok
        end
      end

  A custom dispatcher that never calls this function still delivers to
  tagged subscribers, but the messages arrive unwrapped. See the "Tagged
  subscriptions" section in the module documentation.
  """
  @spec tag_message(term, message) :: message
  def tag_message(metadata, message)
  def tag_message({__MODULE__, tag}, message), do: {tag, message}
  def tag_message(_metadata, message), do: message

  ## Dispatch callback

  @doc false
  def dispatch(entries, :none, message) do
    for {pid, metadata} <- entries do
      send(pid, tag_message(metadata, message))
    end

    :ok
  end

  def dispatch(entries, from, message) do
    for {pid, metadata} <- entries, pid != from do
      send(pid, tag_message(metadata, message))
    end

    :ok
  end

  defp dispatch(pubsub, from, topic, message, dispatcher) do
    Registry.dispatch(pubsub, topic, {dispatcher, :dispatch, [from, message]})
    :ok
  end
end
