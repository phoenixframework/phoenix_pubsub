Enum.each(Path.wildcard("tasks/*.exs"), &Code.require_file/1)

defmodule Phoenix.PubSub.Mixfile do
  use Mix.Project

  @version "1.1.2"

  def project do
    [
      app: :phoenix_pubsub,
      version: @version,
      elixir: "~> 1.4",
      description: "Distributed PubSub and Presence platform",
      homepage_url: "http://www.phoenixframework.org",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      applications: [:logger, :crypto],
      mod: {Phoenix.PubSub.Supervisor, []}
    ]
  end

  defp deps do
    [
      {:dialyze, "~> 0.2.0", only: :dev},
      {:ex_doc, ">= 0.0.0", only: :docs}
    ]
  end

  defp package do
    [
      maintainers: ["Chris McCord", "José Valim", "Alexander Songe", "Gary Rennie"],
      licenses: ["MIT"],
      links: %{github: "https://github.com/phoenixframework/phoenix_pubsub"},
      files: ~w(lib test/shared CHANGELOG.md LICENSE.md mix.exs README.md)
    ]
  end

  defp docs do
    [
      main: "Phoenix.PubSub",
      source_ref: "v#{@version}",
      source_url: "https://github.com/phoenixframework/phoenix_pubsub"
    ]
  end
end
