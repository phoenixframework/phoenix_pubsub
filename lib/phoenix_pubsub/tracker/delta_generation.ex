defmodule Phoenix.Tracker.DeltaGeneration do
  @moduledoc false
  require Logger
  alias Phoenix.Tracker.{State, Clock}

  @doc """
  Extracts minimal delta from generations to satisfy remote clock.

  Falls back to extracting entire crdt if unable to match delta.
  """
  @spec extract(State.delta, [State.delta], State.context) :: State.delta | State.t
  def extract(%State{mode: :normal} = state, generations, remote_clock) do
    case delta_fullfilling_clock(generations, remote_clock) do
      {delta, index} ->
        if index, do: Logger.debug "#{inspect state.replica}: sending delta generation #{index + 1}"
        delta
      nil ->
        Logger.debug "#{inspect state.replica}: falling back to sending entire crdt"
        State.extract(state)
    end
  end

  @spec push(State.t, [State.delta], State.delta, [pos_integer]) :: [State.delta]
  def push(%State{mode: :normal} = parent, [] = _generations, %State{mode: :delta} = delta, opts) do
    parent.delta
    |> List.duplicate(Enum.count(opts))
    |> do_push(delta, opts, {delta, []})
  end
  def push(%State{mode: :normal} = _parent, generations, %State{mode: :delta} = delta, opts) do
    do_push(generations, delta, opts, {delta, []})
  end
  defp do_push([], _delta, [], {_prev, acc}), do: Enum.reverse(acc)
  defp do_push([gen | generations], delta, [gen_max | opts], {prev, acc}) do
    case State.merge_deltas(gen, delta) do
      {:ok, merged} ->
        if State.delta_size(merged) <= gen_max do
          do_push(generations, delta, opts, {merged, [merged | acc]})
        else
          do_push(generations, delta, opts, {merged, [prev | acc]})
        end

      {:error, :not_contiguous} ->
        do_push(generations, delta, opts, {gen, [gen | acc]})
    end
  end

  defp delta_fullfilling_clock(generations, remote_clock) do
    generations
    |> Enum.with_index()
    |> Enum.find(fn {%State{range: {local_start, _local_end}}, _} ->
      Clock.dominates?(remote_clock, local_start)
    end)
  end
end
