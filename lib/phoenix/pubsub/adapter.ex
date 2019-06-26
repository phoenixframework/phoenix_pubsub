defmodule Phoenix.PubSub.Adapter do
  @moduledoc """
  Specification to implement a custom PubSub adater.
  """
  @type adapter_name :: atom

  @callback node_name(adapter_name) :: Phoenix.PubSub.node_name()

  @callback child_spec(keyword) :: Supervisor.child_spec()

  @callback broadcast(
              adapter_name,
              Phoenix.PubSub.topic(),
              Phoenix.PubSub.message(),
              Phoenix.PubSub.dispatcher()
            ) :: :ok | {:error, term}

  @callback direct_broadcast(
              adapter_name,
              Phoenix.PubSub.node_name(),
              Phoenix.PubSub.topic(),
              Phoenix.PubSub.message(),
              Phoenix.PubSub.dispatcher()
            ) :: :ok | {:error, term}
end
