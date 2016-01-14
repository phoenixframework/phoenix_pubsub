defmodule Phoenix.Presence.VectorClock do

  def inc(node, clocks) do
    Map.update(clocks, node, 0, &(&1 + 1))
  end

  def merge_clocks(node, clocks, remote_clocks) do
    clocks
    |> Map.merge(remote_clocks, fn _node, c1, c2 -> Enum.max([c1, c2]) end)
    |> Map.put(node, clocks[node])
  end

  def collapse_clocks(node, my_clocks, pending_clocks) do
    merged = Enum.reduce(pending_clocks, my_clocks, fn {_node, clocks}, acc ->
      merge_clocks(node, acc, clocks)
    end)

    needs_synced =
      merged
      |> Enum.filter(fn {node, clock} ->
         my_value = my_clocks[node]
         is_nil(my_value) || my_value < clock
      end)
      |> Enum.group_by(fn {to_sync_node, to_sync_clock} ->
        find_node_in_future_of(pending_clocks, to_sync_node, to_sync_clock)
      end)

    {merged, needs_synced}
  end

  defp find_node_in_future_of(pending_clocks, to_sync_node, to_sync_clock) do
    pending_clocks
    |> Enum.find(fn {_, clocks} -> clocks[to_sync_node] == to_sync_clock end)
    |> case do
      {node, _} -> node
      _ -> nil
    end
  end
end
