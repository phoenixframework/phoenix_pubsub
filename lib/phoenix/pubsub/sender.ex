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

  The state is an accumulator and be used to cache data in between sends to different
  subscriptions. For example, if the message needs to be serialized into a custom format,
  using `state` allows to implement a fastlane approach, where you can serialize the
  message once and then reuse the serialized message on subsequent calls.
  The first `send/4` invocation will pass a state of `nil` and subsequent calls
  will pass the previously returned value.
  """

  @callback send(pid :: pid(), meta :: term(), message :: term(), state :: term()) :: term()
end
