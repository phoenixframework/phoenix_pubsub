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
      opts[:pool_size] ||
        System.schedulers_online() |> Kernel./(4) |> Float.ceil() |> trunc()

    registry = [
      meta: [pubsub: {adapter, adapter_name}],
      partitions: partitions,
      keys: :duplicate,
      name: name
    ]

    children = [
      {Registry, registry},
      {adapter, Keyword.put(opts, :adapter_name, adapter_name)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
