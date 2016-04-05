use Mix.Config

config :phoenix_pubsub,
  pubsub: [Phoenix.PubSub.Test.PubSub, [pool_size: 1]],
  nodes: [:"replica1@127.0.0.1", :"replica2@127.0.0.1"]

config :logger,
  level: :info,
  compile_time_purge_level: :info
