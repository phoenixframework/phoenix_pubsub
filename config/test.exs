use Mix.Config

config :phoenix_pubsub, :nodes,
  names: [:"slave1@127.0.0.1", :"slave2@127.0.0.1"]
