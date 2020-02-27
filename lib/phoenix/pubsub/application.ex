defmodule Phoenix.PubSub.Application do
  use Application

  def start(_, _) do
    children = pg_children()
    Supervisor.start_link(children, strategy: :one_for_one)
  end

  if Code.ensure_loaded?(:pg) do
    defp pg_children() do
      [%{id: :pg, start: {:pg, :start_link, [Phoenix.PubSub]}}]
    end
  else
    defp pg_children() do
      []
    end
  end
end