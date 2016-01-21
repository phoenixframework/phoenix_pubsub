# Phoenix.PubSub


## Installation


  1. Add phoenix_presence to your list of dependencies in `mix.exs`:

        def deps do
          [{:phoenix_pubsub, "~> 0.0.1"}]
        end

  2. Ensure phoenix_presence is started before your application:

        def application do
          [applications: [:phoenix_pubsub]]
        end


## Testing

Full testing requires multiple nodes. Start two nodes as slaves before running the test suite:

    $ MIX_ENV=test iex --name slave1@127.0.0.1 -S mix
    $ MIX_ENV=test iex --name slave2@127.0.0.1 -S mix

Then run the tests as normal:

    $ mix test
