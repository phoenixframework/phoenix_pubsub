defmodule Phoenix.PubSub.PG2 do
  @moduledoc """
  Phoenix PubSub adapter based on `:pg2`.

  It runs on Distributed Erlang and is the default adapter.
  """

  use GenServer
  @behaviour Phoenix.PubSub.Adapter

  ## Adapter callbacks

  @impl true
  def node_name(_), do: node()

  @impl true
  def broadcast(adapter_name, topic, message, dispatcher) do
    case :pg2.get_members(pg2_namespace(adapter_name)) do
      {:error, {:no_such_group, _}} ->
        {:error, :no_such_group}

      pids ->
        message = forward_to_local(topic, message, dispatcher)

        for pid <- pids, node(pid) != node() do
          send(pid, message)
        end

        :ok
    end
  end

  @impl true
  def direct_broadcast(adapter_name, node_name, topic, message, dispatcher) do
    send({adapter_name, node_name}, {:forward_to_local, topic, message, dispatcher})
    :ok
  end

  defp forward_to_local(topic, message, dispatcher) do
    {:forward_to_local, topic, message, dispatcher}
  end

  ## GenServer callbacks

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    adapter_name = Keyword.fetch!(opts, :adapter_name)
    GenServer.start_link(__MODULE__, {name, adapter_name}, name: adapter_name)
  end

  @impl true
  def init({name, adapter_name}) do
    pg2_group = pg2_namespace(adapter_name)
    :ok = :pg2.create(pg2_group)
    :ok = :pg2.join(pg2_group, self())
    {:ok, name}
  end

  def handle_info({:forward_to_local, topic, message, dispatcher}, pubsub) do
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)
    {:noreply, pubsub}
  end

  @impl true
  def handle_info(_, pubsub) do
    {:noreply, pubsub}
  end

  defp pg2_namespace(server_name), do: {:phx, server_name}
end
