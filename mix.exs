defmodule Phoenix.PubSub.Mixfile do
  use Mix.Project

  def project do
    [app: :phoenix_pubsub,
     version: "0.0.1",
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  def application do
    [applications: [:logger, :phoenix, :presence],
     mod: {Phoenix.PubSub.Supervisor, []}]
  end

  defp deps do
    [{:phoenix, path: "~/Workspace/projects/phoenix"},
     {:presence, github: "asonge/phoenix_presence"}]
  end
end
