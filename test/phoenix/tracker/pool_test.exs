defmodule Phoenix.Tracker.PoolTest do
  use Phoenix.PubSub.NodeCase
  alias Phoenix.Tracker

  setup config do
    server = config.test
    {:ok, _pid} = start_pool(name: server, pool_size: config.pool_size)
    {:ok, server: server}
  end

  for n <- [1,2,8,512] do

    @tag pool_size: n
    test "pool #{n}: A track/5 call results in the id being tracked",
      %{server: server} do
      {:ok, ref} = Tracker.track(server, self(), "topic", "me", %{name: "me"})
      assert [{"me", %{name: "me", phx_ref: ^ref}}]
      = Tracker.list(server, "topic")
    end

    @tag pool_size: n
    test "pool #{n}: dirty_list/2 returns tracked ids", %{server: server} do
      {:ok, ref} = Tracker.track(server, self(), "topic", "me", %{name: "me"})
      assert [{"me", %{name: "me", phx_ref: ^ref}}]
      = Tracker.dirty_list(server, "topic")
    end

    @tag pool_size: n
    test "pool #{n}: Track/5 results in all ids being tracked",
    %{server: server} do

      topics = for i <- 1..100, do: "topic_#{i}"

      refs = for topic <- topics do
        {:ok, ref} = Tracker.track(server, self(), topic, "me", %{name: "me"})
        ref
      end

      for {t, ref} <- List.zip([topics, refs]) do
        assert Tracker.list(server, t) == [{"me", %{name: "me", phx_ref: ref}}]
      end
    end

    @tag pool_size: n
    test "pool #{n}: Untrack/4 results in all ids being untracked",
    %{server: server} do
      topics = for i <- 1..100, do: "topic_#{i}"
      for t <- topics do
        {:ok, _ref} = Tracker.track(server, self(), t, "me", %{a: "b"})
      end
      for t <- topics, do: :ok = Tracker.untrack(server, self(), t, "me")

      for t <- topics, do: assert Tracker.list(server, t) == []
    end

    @tag pool_size: n
    test "pool #{n}: Untrack/2 results in all ids being untracked",
    %{server: server} do
      topics = for i <- 1..100, do: "topic_#{i}"
      for t <- topics do
        {:ok, _ref} = Tracker.track(server, self(), t, "me", %{a: "b"})
      end
      :ok = Tracker.untrack(server, self())

      for t <- topics, do: assert Tracker.list(server, t) == []
    end


    @tag pool_size: n
    test "pool #{n}: Update/5 updates a given trackees metas",
    %{server: server} do
      topics = for i <- 1..100, do: "topic_#{i}"
      old_refs = for t <- topics do
        {:ok, ref} = Tracker.track(server, self(), t, "me", %{a: "b"})
        ref
      end
      new_refs = for t <- topics do
        {:ok, new_ref} = Tracker.update(server, self(), t, "me", %{new: "thing"})
        new_ref
      end

      expected_changes = List.zip([topics, old_refs, new_refs])

      for {t, old_ref, new_ref} <- expected_changes do
        assert [{"me", %{new: "thing",
                         phx_ref: ^new_ref,
                         phx_ref_prev: ^old_ref}}]
        = Tracker.list(server, t)
      end
    end

    @tag pool_size: n
    test "pool #{n}: Update/5 applies fun to given trackees metas",
    %{server: server} do
      topics = for i <- 1..100, do: "topic_#{i}"
      old_refs = for t <- topics do
        {:ok, ref} = Tracker.track(server, self(), t, "me", %{a: "oldval"})
        ref
      end

      update_fun = fn(m) -> Map.put(m, :a, "newval") end

      new_refs = for t <- topics do
        {:ok, new_ref} = Tracker.update(server, self(), t, "me", update_fun)
        new_ref
      end

      expected_changes = List.zip([topics, old_refs, new_refs])

      for {t, old_ref, new_ref} <- expected_changes do
        assert [{"me", %{a: "newval",
                         phx_ref: ^new_ref,
                         phx_ref_prev: ^old_ref}}]
        = Tracker.list(server, t)
      end
    end

    @tag pool_size: n
    test "pool #{n}: Graceful_permdown/2 results in all ids being untracked",
    %{server: server, pool_size: n} do
      topics = for i <- 1..100, do: "topic_#{i}"
      for t <- topics do
        {:ok, _ref} = Tracker.track(server, self(), t, "me", %{a: "b"})
      end
      :ok = Tracker.graceful_permdown(server)
      :timer.sleep(n)

      for t <- topics, do: assert Tracker.list(server, t) == []
    end

  end

end
