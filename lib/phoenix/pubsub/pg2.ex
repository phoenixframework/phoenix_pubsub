defmodule Phoenix.PubSub.PG2 do
  @moduledoc """
  Phoenix PubSub adapter based on `:pg`/`:pg2`.

  It runs on Distributed Erlang and is the default adapter.
  """

  @behaviour Phoenix.PubSub.Adapter
  use Supervisor

  ## Adapter callbacks

  @impl true
  def node_name(_), do: node()

  @impl true
  def broadcast(adapter_name, topic, message, dispatcher) do
    case pg_members(group(adapter_name)) do
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
    send({group(adapter_name), node_name}, {:forward_to_local, topic, message, dispatcher})
    :ok
  end

  defp forward_to_local(topic, message, dispatcher) do
    {:forward_to_local, topic, message, dispatcher}
  end

  defp group(adapter_name) do
    groups = :persistent_term.get(adapter_name)
    elem(groups, :erlang.phash2(self(), tuple_size(groups)))
  end

  if Code.ensure_loaded?(:pg) do
    defp pg_members(group) do
      :pg.get_members(Phoenix.PubSub, group)
    end
  else
    defp pg_members(group) do
      :pg2.get_members({:phx, group})
    end
  end

  ## Supervisor callbacks

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, 1)
    broadcast_pool_size = Keyword.get(opts, :broadcast_pool_size, pool_size)

    if pool_size < broadcast_pool_size do
      {:error, "the :pool_size option must be greater than or equal to the :broadcast_pool_size option"}
    else
      adapter_name = Keyword.fetch!(opts, :adapter_name)
      Supervisor.start_link(__MODULE__, {name, adapter_name, pool_size, broadcast_pool_size}, name: :"#{adapter_name}_supervisor")
    end
  end

  @impl true
  def init({name, adapter_name, pool_size, broadcast_pool_size}) do

    listener_groups = groups(adapter_name, pool_size)
    broadcast_groups = groups(adapter_name, broadcast_pool_size)

    :persistent_term.put(adapter_name, List.to_tuple(broadcast_groups))

    children =
      for group <- listener_groups do
        Supervisor.child_spec({Phoenix.PubSub.PG2Worker, {name, group}}, id: group)
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp groups(adapter_name, pool_size) do
    [_ | groups] =
      for number <- 1..pool_size do
        :"#{adapter_name}_#{number}"
      end

    # Use `adapter_name` for the first in the pool for backwards compatibility
    # with v2.0 when the pool_size is 1.
    [adapter_name | groups]
  end
end

defmodule Phoenix.PubSub.PG2Worker do
  @moduledoc false
  use GenServer

  @doc false
  def start_link({name, group}) do
    GenServer.start_link(__MODULE__, {name, group}, name: group)
  end

  @impl true
  def init({name, group}) do
    :ok = pg_join(group)
    {:ok, name}
  end

  @impl true
  def handle_info({:forward_to_local, topic, message, dispatcher}, pubsub) do
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)
    {:noreply, pubsub}
  end

  @impl true
  def handle_info(_, pubsub) do
    {:noreply, pubsub}
  end

  if Code.ensure_loaded?(:pg) do
    defp pg_join(group) do
      :ok = :pg.join(Phoenix.PubSub, group, self())
    end
  else
    defp pg_join(group) do
      namespace = {:phx, group}
      :ok = :pg2.create(namespace)
      :ok = :pg2.join(namespace, self())
      :ok
    end
  end
end
