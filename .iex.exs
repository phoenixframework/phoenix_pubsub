Phoenix.PubSub.subscribe(Phoenix.Presence.PubSub, self, "iex")
Phoenix.Presence.Server.track(Phoenix.Presence.PubSub, self, "iex", node(), %{})

list = fn topic -> Phoenix.Presence.Server.list(Phoenix.Presence.PubSub, topic) end
presence = fn topic, id, meta ->
  spawn_link fn ->
    Phoenix.Presence.Server.track(Phoenix.Presence.PubSub, self, topic, id, meta)
    :timer.sleep(30_000)
  end
end
