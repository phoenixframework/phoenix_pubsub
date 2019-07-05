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

  test "whole state is extracted if there are no deltas", config do
    pid = new_pid()
    s1 = new(:r1, config)
    s2 = State.join(s1, pid, "lobby", "user1", %{})

    expected_state = %{s2 | pids: nil, tags: nil, values: nil, delta: :unset}
    expected_values = %{{:r1, 1} => {pid, "lobby", "user1", %{}}}

    assert DeltaGeneration.extract(s2, [], :r2, %{r1: 1}) ==
      {expected_state, expected_values}
  end

  test "delta is extracted for the first delta with dominating clocks", config do
    pid = new_pid()
    s1 = new(:r1, config)
    s2 = State.join(State.reset_delta(s1), pid, "lobby", "user1", %{})
    d2 = s2.delta
    s3 = State.join(State.reset_delta(s2), pid, "lobby", "user2", %{})
    d3 = s3.delta

    assert DeltaGeneration.extract(s3, [d2, d3], :r2, %{r1: 1}) == d3
  end

  test "an empty delta is not extracted", config do
    pid = new_pid()
    s1 = new(:r1, config)
    s2 = State.join(s1, pid, "lobby", "user1", %{})
    d1 = s2.delta
    d2 = State.reset_delta(s2).delta

    {d1_left, d1_right} = d1.range
    d3 = %{d1 |
      range: {Map.put(d1_left, :r2, 0), Map.put(d1_right, :r2, 1)},
      values: Map.put(d1.values, {:r2, 1}, {pid, "lobby", "user2", %{}})}
    s3 = %{s2 | delta: d3}

    expected_delta = %{d3 |
      clouds: %{},
      range: {%{r2: 0}, %{r2: 1}},
      values: %{{:r2, 1} => {pid, "lobby", "user2", %{}}}}

    assert DeltaGeneration.extract(s3, [d2, d3], :r3, %{r2: 0}) == expected_delta
  end

  test "delta that isn't dominating on common set of replicas is not extracted", config do
    pid = new_pid()
    s1 = new(:r1, config)
    s2 = State.join(s1, pid, "lobby", "user1", %{})
    d1 = s2.delta

    s3 = State.join(s2, pid, "lobby", "user2", %{})
    d2 = s3.delta

    {d1_left, d1_right} = d1.range
    d1 = %{d1 | range: {Map.put(d1_left, :r2, 0), Map.put(d1_right, :r2, 1)}}

    assert DeltaGeneration.extract(s3, [d1, d2], :r3, %{r1: 1}) == d2
  end
end
