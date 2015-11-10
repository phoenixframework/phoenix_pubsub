defmodule Phoenix.Presence.Adapter do
  @moduledoc """
  The Behaviour for defining a Phoenix presence adapter
  """

  use Behaviour

  defcallback node() :: :atom

  defcallback start_link(opts :: Keyword.t) :: {:ok, Pid} | {:error, reason :: term}

  defcallback monitor_nodes(pid :: Pid) :: :ok | {:error, reason :: term}

  defcallback demonitor_nodes(pid :: Pid) :: :ok | {:error, reason :: term}

  defcallback list() :: node_list :: List.t

  defcallback request_transfer(pubsub_server :: atom, source_node :: {node :: atom, Pid}, topic :: atom) :: Ref | :no_members

  defcallback transfer(pubsub_server :: atom, reference, from_node :: atom, dest_node :: atom, group_name :: atom, payload :: term)
    :: reference
end
