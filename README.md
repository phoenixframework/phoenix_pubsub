# Phoenix.PubSub
> Distributed PubSub and Presence platform for the Phoenix Framework

[![Build Status](https://api.travis-ci.org/phoenixframework/phoenix_pubsub.svg)](https://travis-ci.org/phoenixframework/phoenix_pubsub)


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

Testing by default spawns nodes internally for distributed tests.
To run tests that do not require clustering, exclude  the `clustered` tag:

    $ mix test --exclude clustered
