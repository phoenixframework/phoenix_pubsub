defmodule Phoenix.PubSub.Mixfile do
  use Mix.Project

  def project do
    [app: :phoenix_pubsub,
     version: "0.0.1",
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     elixirc_paths: elixirc_paths(Mix.env),
     deps: deps]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_),     do: ["lib"]

  def application do
    [applications: [:logger, :phoenix],
     mod: {Phoenix.PubSub.Supervisor, []}]
  end

  defp deps do
    [{:phoenix, github: "phoenixframework/phoenix"},
     {:dialyze, "~> 0.2.0", only: :dev}]
  end
end
