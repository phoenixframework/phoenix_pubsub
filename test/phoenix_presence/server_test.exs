defmodule Phoenix.Presence.ServerTest do
  use ExUnit.Case, async: false
  alias Phoenix.Presence.Server

  setup_all do
    {:ok, _} = Phoenix.Presence.Adapters.Global.start_link([])
    {:ok, _} = Phoenix.PubSub.PG2.start_link(:server_pub, pool_size: 1)
    {:ok, _} = Phoenix.Presence.Tracker.start_link([pubsub_server: :server_pub])
    :ok
  end

end
