defmodule Phoenix.Presence.Mixfile do
  use Mix.Project

  def project do
    [app: :phoenix_presence,
     version: "0.0.1",
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  def application do
    [applications: [:logger, :phoenix],
     mod: {Phoenix.Presence, []}]
  end

  defp deps do
    [{:phoenix, "~> 1.0"}]
  end
end
