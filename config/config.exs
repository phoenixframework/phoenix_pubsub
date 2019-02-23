use Mix.Config

config :phoenix_pubsub,
  pubsub: [Phoenix.PubSub.Test.PubSub, [pool_size: 1]],
  nodes: [:"node1@127.0.0.1", :"node2@127.0.0.1"]

config :logger,
  level: :info,
  compile_time_purge_level: :info
