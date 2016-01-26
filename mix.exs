defmodule Phoenix.PubSub.Mixfile do
  use Mix.Project

  def project do
    [app: :phoenix_pubsub,
     version: "0.0.1",
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     elixirc_paths: elixirc_paths(Mix.env),
     package: package,
     deps: deps]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_),     do: ["lib"]

  def application do
    [applications: [:logger],
     mod: {Phoenix.PubSub.Supervisor, []}]
  end

  defp deps do
    [{:dialyze, "~> 0.2.0", only: :dev}]
  end

  defp package do
    [maintainers: ["Chris McCord", "José Valim", "Alexander Songe"],
     licenses: ["MIT"],
     links: %{github: "https://github.com/phoenixframework/phoenix_pubsub"},
     files: ~w(lib priv test/shared) ++
            ~w(CHANGELOG.md LICENSE.md mix.exs README.md)]
  end
end
