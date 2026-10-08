defmodule Phoenix.PubSub.Sender do
  @moduledoc """
  Defines a custom message sender.

  When subscribing, a client can pass an optional `:sender`, which will
  be used when performing local message deliveries for this subscription.

  For example, a custom sender could prefix delivered messages to differentiate
  messages that share the same format from different topics, by including
  a topic reference in the sender metadata.

  ## Example

      defmodule MySender do
        @behaviour Phoenix.PubSub.Sender

        @impl true
        def send(pid, {:custom, topic}, message, state) do
          send(pid, {:pubsub_message, topic, message})
          state
        end
      end

      iex> Phoenix.PubSub.subscribe(MyApp.PubSub, "topic", sender: {MySender, {:custom, "topic"}})

  ## State and caching

  The state is an accumulator that can cache data between sends to different
  subscriptions. For example, a sender can serialize a message once, return the
  serialized data as state, and reuse it for subsequent subscribers instead of
  serializing the same message for each delivery.

  Each broadcast starts a separate accumulator for each sender module in each
  Registry partition. The first `send/4` invocation receives `nil` and subsequent
  calls for that module within the same partition receive the previously returned
  value. State is not shared across partitions or retained between broadcasts.

  Subscriptions with different metadata but the same sender module share the
  accumulator within a partition. If serialization depends on the metadata,
  key cached data by the relevant metadata, such as the serializer or format.

  After all deliveries in a Registry partition complete, the optional `finalize/1`
  callback is called once for each sender module that was invoked and implements
  it, with its final accumulated state.
  This callback can release resources or flush work accumulated during delivery.
  Its return value is ignored. Sender modules are finalized in no particular order.
  """

  @callback send(pid :: pid(), meta :: term(), message :: term(), state :: term()) :: term()

  @doc """
  Finalizes a sender's accumulated state after dispatch completes in a Registry partition.

  This callback is optional. Its return value is ignored.
  """
  @callback finalize(state :: term()) :: term()

  @optional_callbacks finalize: 1
end
