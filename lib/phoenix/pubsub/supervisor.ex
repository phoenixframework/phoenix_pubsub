defmodule Phoenix.PubSub.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    unless Code.ensure_loaded?(:persistent_term) do
      raise "Phoenix.PubSub v2.1 requires at least Erlang/OTP 21.3"
    end

    name =
      opts[:name] ||
        raise ArgumentError, "the :name option is required when starting Phoenix.PubSub"

    sup_name = Module.concat(name, "Supervisor")
    Supervisor.start_link(__MODULE__, opts, name: sup_name)
  end

  @impl true
  def init(opts) do
    name = opts[:name]
    adapter = opts[:adapter] || Phoenix.PubSub.PG2
    adapter_name = Module.concat(name, "Adapter")

    partitions =
      opts[:registry_size] || opts[:pool_size] ||
        System.schedulers_online() |> Kernel./(4) |> Float.ceil() |> trunc()

    dispatcher = Keyword.get(opts, :dispatcher, Phoenix.PubSub)
    keys = registry_keys(Keyword.get(opts, :group_by, :pid))

    registry = [
      meta: [pubsub: {adapter, adapter_name, dispatcher}],
      partitions: partitions,
      keys: keys,
      name: name
    ]

    children = [
      {Registry, registry},
      {adapter, Keyword.put(opts, :adapter_name, adapter_name)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp registry_keys(:pid), do: :duplicate
  defp registry_keys(:key), do: {:duplicate, :key}

  defp registry_keys(other) do
    raise ArgumentError,
          "invalid :group_by option (got #{inspect(other)}), must be :pid or :key"
  end
end
