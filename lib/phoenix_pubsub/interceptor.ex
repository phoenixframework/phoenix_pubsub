defmodule Phoenix.PubSub.Interceptor do
  @moduledoc ~S"""
  A behaviour for intercepting PubSub messages before they are relayed locally.

  Allows broadcasted messages to be intercepted before being forwarded to
  node-local subscribers. Useful for customizing and filtering messages
  before subscribers receive them.

  ## Examples

      defmodule MyApp.PubSub.Interceptor do
        use Phoenix.PubSub.Interceptor

        def handle_broadcast("topic1", msg, _server) do
          :ignore # do not relay message to subscribers
        end

        def handle_broadcast("topic2", :ping, _server) do
          {:ok, :pang} # custmize message before relaying to subscribers
        end

        def handle_broadcast("topic3", :ping, server) do
          # broadcast additional message to local subscribers
          Phoenix.PubSub.local_broadcast(server, "another:topic", :intercepted)
          {:ok, :ping}
        end
      end
  """
  @type topic :: String.t
  @type message :: term
  @type pubsub_server :: atom

  @callback handle_broadcast(topic, message, pubsub_server) :: {:ok, message} | :ignore

  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__)
      @before_compile unquote(__MODULE__)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def handle_broadcast(_topic, message, _pubsub_server), do: {:ok, message}
    end
  end
end
