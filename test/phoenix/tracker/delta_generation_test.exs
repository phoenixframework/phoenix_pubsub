defmodule Phoenix.Tracker.DeltaGenerationTest do
  use ExUnit.Case, async: true
  alias Phoenix.Tracker.{State, DeltaGeneration}
  import DeltaGeneration

  defp new(node) do
    State.new(node)
  end

  defp new_pid() do
    spawn(fn -> :ok end)
  end

  defp keys(delta) do
    delta.values
    |> Enum.map(fn {_tag, {_pid, _topic, key, _meta}} -> key end)
    |> Enum.sort()
  end

  test "generations" do
    s1 = new(:s1)
    s2 = new(:s2)
    s1 = State.join(s1, new_pid(), "lobby", "user1", %{})
    assert [gen1, gen1, gen1] = gens = push(s1, [], s1.delta, [2, 5, 6])
    assert keys(gen1) == ["user1"]
    assert Enum.to_list(gen1.cloud) == [{:s1, 1}]
    # dups merges have no effect
    assert [^gen1, ^gen1, ^gen1] = push(s1, gens, s1.delta, [2, 5, 6])

    s1 = State.reset_delta(s1)
    s1 = State.join(s1, new_pid(), "lobby", "user2", %{})
    assert [gen1, gen2, gen3] = gens = push(s1, gens, s1.delta, [2, 5, 6])
    assert keys(gen1) == ["user2"]
    assert keys(gen2) == ["user1", "user2"]
    assert keys(gen3) == ["user1", "user2"]
    assert Enum.sort(gen1.cloud) == [{:s1, 2}]
    assert Enum.sort(gen2.cloud) == [{:s1, 1}, {:s1, 2}]
    assert Enum.sort(gen3.cloud) == [{:s1, 1}, {:s1, 2}]

    s1 = State.reset_delta(s1)
    s1 = State.join(s1, new_pid(), "lobby", "user3", %{})
    assert [gen1, gen2, gen3] = gens = push(s1, gens, s1.delta, [2, 5, 6])
    assert gen1 == s1.delta
    assert keys(gen1) == ["user3"]
    assert keys(gen2) == ["user2", "user3"]
    assert keys(gen3) == ["user1", "user2", "user3"]
    assert Enum.sort(gen1.cloud) == [{:s1, 3}]
    assert Enum.sort(gen2.cloud) == [{:s1, 2}, {:s1, 3}]
    assert Enum.sort(gen3.cloud) == [{:s1, 1}, {:s1, 2}, {:s1, 3}]

    s1 = State.reset_delta(s1)
    s1 = State.join(s1, new_pid(), "lobby", "user4", %{})
    assert [gen1, gen2, gen3] = gens = push(s1, gens, s1.delta, [2, 5, 6])
    assert keys(gen1) == ["user4"]
    assert keys(gen2) == ["user3", "user4"]
    assert keys(gen3) == ["user2", "user3", "user4"]
    assert Enum.sort(gen1.cloud) == [{:s1, 4}]
    assert Enum.sort(gen2.cloud) == [{:s1, 3}, {:s1, 4}]
    assert Enum.sort(gen3.cloud) == [{:s1, 2}, {:s1, 3}, {:s1, 4}]

    # remote deltas
    user5 = new_pid()
    s2 = State.join(s2, user5, "lobby", "user5", %{})
    assert [gen1, gen2, gen3] = gens = push(s1, gens, s2.delta, [2, 5, 6])
    assert keys(gen1) == ["user5"]
    assert keys(gen2) == ["user4", "user5"]
    assert keys(gen3) == ["user3", "user4", "user5"]
    assert Enum.sort(gen1.cloud) == [{:s2, 1}]
    assert Enum.sort(gen2.cloud) == [{:s1, 4}, {:s2, 1}]
    assert Enum.sort(gen3.cloud) == [{:s1, 3}, {:s1, 4}, {:s2, 1}]

    # tombstones
    s2 = State.leave(s2, user5)
    assert [gen1, gen2, gen3] = push(s1, gens, s2.delta, [2, 5, 6])
    assert keys(gen1) == []
    assert keys(gen2) == ["user4"]
    assert keys(gen3) == ["user3", "user4"]
    assert Enum.sort(gen1.cloud) == [{:s2, 1}, {:s2, 2}]
    assert Enum.sort(gen2.cloud) == [{:s1, 4}, {:s2, 1}, {:s2, 2}]
    assert Enum.sort(gen3.cloud) == [{:s1, 3}, {:s1, 4}, {:s2, 1}, {:s2, 2}]
  end

  test "does not include non-contiguous deltas" do
    s1 = new(:s1)
    s3 = new(:s3)
    s1 = State.join(s1, new_pid(), "lobby", "user1", %{})
    old_s3 = s3 = State.join(s3, new_pid(), "lobby", "user3", %{})
    s3 = State.reset_delta(s3)
    s3 = State.join(s3, new_pid(), "lobby", "user3", %{})
    s3 = State.reset_delta(s3)
    s3 = State.join(s3, new_pid(), "lobby", "user3", %{})
    assert [gen1, gen1, gen1] = gens = push(s1, [], old_s3.delta, [5, 10, 15])
    assert [^gen1, ^gen1, ^gen1] = push(s1, gens, s3.delta, [5, 10, 15])
  end

  test "remove_down_replicas" do
    s1 = new(:s1)
    s2 = new(:s2)
    s3 = new(:s3)
    s2 = State.join(s2, new_pid(), "lobby", "user2", %{})
    assert [gen1, gen1, gen1] = gens = push(s1, [], s2.delta, [5, 10, 15])
    assert [pruned_gen1, pruned_gen1, pruned_gen1] = DeltaGeneration.remove_down_replicas(gens, :s2)
    assert {s3, [], []} = State.merge(s3, pruned_gen1)
    assert State.get_by_topic(s3, "lobby") == []
  end
end
