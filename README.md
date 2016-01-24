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

Testing by default spawns slave nodes internally for distributed tests.
To run tests that do not require slave nodes, exclude  the `clustered` tag:

    $ mix test --exclude clustered
