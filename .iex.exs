Phoenix.PubSub.subscribe(Phoenix.Presence.PubSub, self, "iex")
Phoenix.Presence.Tracker.track(RoomChannel, self(), "iex", node())

list = fn topic -> Phoenix.Presence.Tracker.list(RoomChannel, topic) end
presence = fn topic, id ->
  spawn_link fn ->
    Phoenix.Presence.Tracker.track(RoomChannel, self(), topic, id)
    :timer.sleep(30_000)
  end
end
