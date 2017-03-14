defmodule Phoenix.Tracker.DeltaGenerationTest do
  use ExUnit.Case, async: true
  alias Phoenix.Tracker.{State, DeltaGeneration}
  import DeltaGeneration

  def sorted_clouds(clouds) do
    clouds
    |> Enum.flat_map(fn {_name, cloud} -> Enum.to_list(cloud) end)
    |> Enum.sort()
  end

  defp new(node, config) do
    State.new(node, :"#{node} #{config.test}")
  end

  defp new_pid() do
    spawn(fn -> :ok end)
  end

  defp keys(delta) do
    delta.values
    |> Enum.map(fn {_tag, {_pid, _topic, key, _meta}} -> key end)
    |> Enum.sort()
  end

  test "generations", config do
    s1 = new(:s1, config)
    s2 = new(:s2, config)
    s1 = State.join(s1, new_pid(), "lobby", "user1", %{})
    assert [gen1, gen1, gen1] = gens = push(s1, [], s1.delta, [2, 5, 6])
    assert keys(gen1) == ["user1"]
    assert sorted_clouds(gen1.clouds) == [{:s1, 1}]
    # dups merges have no effect
    assert [^gen1, ^gen1, ^gen1] = push(s1, gens, s1.delta, [2, 5, 6])

    s1 = State.reset_delta(s1)
    s1 = State.join(s1, new_pid(), "lobby", "user2", %{})
    assert [gen1, gen2, gen3] = gens = push(s1, gens, s1.delta, [2, 5, 6])
    assert keys(gen1) == ["user2"]
    assert keys(gen2) == ["user1", "user2"]
    assert keys(gen3) == ["user1", "user2"]
    assert sorted_clouds(gen1.clouds) == [{:s1, 2}]
    assert sorted_clouds(gen2.clouds) == [{:s1, 1}, {:s1, 2}]
    assert sorted_clouds(gen3.clouds) == [{:s1, 1}, {:s1, 2}]

    s1 = State.reset_delta(s1)
    s1 = State.join(s1, new_pid(), "lobby", "user3", %{})
    assert [gen1, gen2, gen3] = gens = push(s1, gens, s1.delta, [2, 5, 6])
    assert gen1 == s1.delta
    assert keys(gen1) == ["user3"]
    assert keys(gen2) == ["user2", "user3"]
    assert keys(gen3) == ["user1", "user2", "user3"]
    assert sorted_clouds(gen1.clouds) == [{:s1, 3}]
    assert sorted_clouds(gen2.clouds) == [{:s1, 2}, {:s1, 3}]
    assert sorted_clouds(gen3.clouds) == [{:s1, 1}, {:s1, 2}, {:s1, 3}]

    s1 = State.reset_delta(s1)
    s1 = State.join(s1, new_pid(), "lobby", "user4", %{})
    assert [gen1, gen2, gen3] = gens = push(s1, gens, s1.delta, [2, 5, 6])
    assert keys(gen1) == ["user4"]
    assert keys(gen2) == ["user3", "user4"]
    assert keys(gen3) == ["user2", "user3", "user4"]
    assert sorted_clouds(gen1.clouds) == [{:s1, 4}]
    assert sorted_clouds(gen2.clouds) == [{:s1, 3}, {:s1, 4}]
    assert sorted_clouds(gen3.clouds) == [{:s1, 2}, {:s1, 3}, {:s1, 4}]

    # remote deltas
    user5 = new_pid()
    s2 = State.join(s2, user5, "lobby", "user5", %{})
    assert [gen1, gen2, gen3] = gens = push(s1, gens, s2.delta, [2, 5, 6])
    assert keys(gen1) == ["user5"]
    assert keys(gen2) == ["user4", "user5"]
    assert keys(gen3) == ["user3", "user4", "user5"]
    assert sorted_clouds(gen1.clouds) == [{:s2, 1}]
    assert sorted_clouds(gen2.clouds) == [{:s1, 4}, {:s2, 1}]
    assert sorted_clouds(gen3.clouds) == [{:s1, 3}, {:s1, 4}, {:s2, 1}]

    # tombstones
    s2 = State.leave(s2, user5)
    assert [gen1, gen2, gen3] = push(s1, gens, s2.delta, [2, 5, 6])
    assert keys(gen1) == []
    assert keys(gen2) == ["user4"]
    assert keys(gen3) == ["user3", "user4"]
    assert sorted_clouds(gen1.clouds) == [{:s2, 1}, {:s2, 2}]
    assert sorted_clouds(gen2.clouds) == [{:s1, 4}, {:s2, 1}, {:s2, 2}]
    assert sorted_clouds(gen3.clouds) == [{:s1, 3}, {:s1, 4}, {:s2, 1}, {:s2, 2}]
  end

  test "does not include non-contiguous deltas", config do
    s1 = new(:s1, config)
    s3 = new(:s3, config)
    s1 = State.join(s1, new_pid(), "lobby", "user1", %{})
    old_s3 = s3 = State.join(s3, new_pid(), "lobby", "user3", %{})
    s3 = State.reset_delta(s3)
    s3 = State.join(s3, new_pid(), "lobby", "user3", %{})
    s3 = State.reset_delta(s3)
    s3 = State.join(s3, new_pid(), "lobby", "user3", %{})
    assert [gen1, gen1, gen1] = gens = push(s1, [], old_s3.delta, [5, 10, 15])
    assert [^gen1, ^gen1, ^gen1] = push(s1, gens, s3.delta, [5, 10, 15])
  end

  test "remove_down_replicas", config do
    s1 = new(:s1, config)
    s2 = new(:s2, config)
    s3 = new(:s3, config)
    s2 = State.join(s2, new_pid(), "lobby", "user2", %{})
    assert [gen1, gen1, gen1] = gens = push(s1, [], s2.delta, [5, 10, 15])
    assert [pruned_gen1, pruned_gen1, pruned_gen1] = DeltaGeneration.remove_down_replicas(gens, :s2)
    assert {s3, [], []} = State.merge(s3, pruned_gen1)
    assert State.get_by_topic(s3, "lobby") == []
  end
end
