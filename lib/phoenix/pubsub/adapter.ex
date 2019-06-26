defmodule Phoenix.PubSub.Adapter do
  @moduledoc """
  Specification to implement a custom PubSub adapter.
  """

  @type adapter_name :: atom

  @doc """
  Returns the node name as an atom or a binary.
  """
  @callback node_name(adapter_name) :: Phoenix.PubSub.node_name()

  @doc """
  Returns a child specification that mounts the processes
  required for the adapter.

  `child_spec` will receive all options given `Phoenix.PubSub`.
  Note, however, that the `:name` under options is the name
  of the complete PubSub system. The name of the process to
  be used by adapter is under the `:adapter_name` key.
  """
  @callback child_spec(keyword) :: Supervisor.child_spec()

  @doc """
  Broadcasts the given topic, message, and dispatcher to
  all nodes in the cluster (except the current node itself).
  """
  @callback broadcast(
              adapter_name,
              Phoenix.PubSub.topic(),
              Phoenix.PubSub.message(),
              Phoenix.PubSub.dispatcher()
            ) :: :ok | {:error, term}

  @doc """
  Broadcasts the given topic, message, and dispatcher to
  given node in the cluster (it may point to itself).
  """
  @callback direct_broadcast(
              adapter_name,
              Phoenix.PubSub.node_name(),
              Phoenix.PubSub.topic(),
              Phoenix.PubSub.message(),
              Phoenix.PubSub.dispatcher()
            ) :: :ok | {:error, term}
end
