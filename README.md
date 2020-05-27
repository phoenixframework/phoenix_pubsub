# Phoenix.PubSub

> Distributed PubSub and Presence platform for the Phoenix Framework

[![Build Status](https://api.travis-ci.org/phoenixframework/phoenix_pubsub.svg)](https://travis-ci.org/phoenixframework/phoenix_pubsub)

## Usage

Add `phoenix_pubsub` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:phoenix_pubsub, "~> 2.0"}]
end
```

Then start your PubSub instance:

```elixir
defmodule MyApp do
  use Application

  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: MyApp.PubSub}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

Now broadcast and subscribe:

```elixir
Phoenix.PubSub.subscribe(MyApp.PubSub, "user:123")
Phoenix.PubSub.broadcast(MyApp.PubSub, "user:123", :hello_world)
```

## Testing

Testing by default spawns nodes internally for distributed tests.
To run tests that do not require clustering, exclude  the `clustered` tag:

```shell
$ mix test --exclude clustered
```

If you have issues running the clustered tests try running:

```shell
$ epmd -daemon
```

before running the tests.
