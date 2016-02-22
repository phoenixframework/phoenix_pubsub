defmodule Phoenix.Tracker.Clock do

  @type context :: Phoenix.Tracker.State.ctx_clock
  @type nodespec :: term
  @type nodeclock :: {nodespec, context}

  @spec clockset_nodes([nodeclock]) :: [nodespec]
  def clockset_nodes(clockset) do
    for {node, _} <- clockset, do: node
  end

  @spec append_clock([nodeclock], nodeclock) :: [nodeclock]
  def append_clock(clockset, {_, clock}) when map_size(clock)==0, do: clockset
  def append_clock(clockset, {node, clock}) do
    big_clock = combine_clocks(clockset)
    cond do
      dominates?(clock, big_clock) -> [{node, clock}]
      dominates?(big_clock, clock) -> clockset
      true -> filter_clocks(clockset, {node, clock})
    end
  end

  def filter_clocks(clockset, {node, clock}) do
    # The acc in the reduce is a tuple of the new clockset, and the current status
    clockset
    |> Enum.reduce({[], false}, fn {node2, clock2}, {set, insert} ->
      if dominates?(clock, clock2) do
        {set, true}
      else
        {[{node2, clock2}|set], insert || !dominates?(clock2, clock)}
      end
    end)
    |> case do
      {new_clockset, true} -> [{node, clock}|new_clockset]
      {new_clockset, false} -> new_clockset
    end
  end

  defp combine_clocks(clockset) do
    clockset
    |> Enum.map(fn {_, clocks} -> clocks end)
    |> Enum.reduce(%{}, &Map.merge(&1, &2, fn _,a,b -> max(a,b) end))
  end

  @spec dominates?(context, context) :: boolean
  # Really fast short-circuit that is just too easy to pass up
  def dominates?(a, b) when map_size(a) < map_size(b), do: false
  def dominates?(a, b) do
    # acc is the map which we will reduce and the status of whether we still dominate
    Enum.reduce(a, {b, true}, &dominates_dot/2) |> does_dominate
  end

  # A simple way of destructuring the return from the reduce...
  # NOTE: assert that b has no leftover data that will cause it to dominate
  defp does_dominate({_, false}), do: false
  defp does_dominate({map, true}), do: map_size(map) == 0

  # How we actually know that we dominate for all clocks in a over those clocks in b
  defp dominates_dot(_, {_, false}), do: {nil, false}
  defp dominates_dot({actor_a, clock_a}, {b, true}) do
    case Map.pop(b, actor_a, 0) do
      {n, _} when n > clock_a -> {nil, false}
      {_, b2} -> {b2, true}
    end
  end

  def upperbound(c1, c2) do
    Map.merge(c1, c2, fn _, v1, v2 -> max(v1, v2) end)
  end

  def lowerbound(c1, c2) do
    Map.merge(c1, c2, fn _, v1, v2 -> min(v1, v2) end)
  end

  def dominates_or_equal?(c1, c2) do
    case Map.keys(c2) -- Map.keys(c1) do
      [] -> Enum.all?(c2, fn {k,v} -> (c1[k]||0) >= v end)
      _ -> false
    end
  end

end
