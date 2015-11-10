defmodule Phoenix.Presence do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      # TODO make it pull adapter from mix config
      # worker(Phoenix.Presence.Adapters.Global, [[]]),
    ]

    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end
end
