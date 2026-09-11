defmodule Phoenix.PubSub.RemoteDispatcher do
  @moduledoc false
  # Tags each delivery with the node whose dispatcher ran, so distributed tests
  # can assert that a dispatcher travels with the message to remote nodes.

  def dispatch(entries, from, message) do
    for {pid, metadata} <- entries do
      send(pid, {:dispatched, node(), metadata, from, message})
    end

    :ok
  end
end

defmodule Phoenix.PubSub.RemoteSender do
  @moduledoc false
  @behaviour Phoenix.PubSub.Sender

  @impl true
  def send(pid, meta, message, state) do
    Kernel.send(pid, {:sent, node(), meta, message, state})
    state
  end
end
