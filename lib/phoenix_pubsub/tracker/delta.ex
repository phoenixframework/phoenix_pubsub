defmodule Phoenix.Tracker.State.Delta do

  alias Phoenix.Tracker.State
  alias Phoenix.Tracker.Clock
  alias Phoenix.Tracker.State.InvariantError

  @type t :: %__MODULE__{
    cloud: MapSet.t, # The dots that we know are in this delta
    dots: %{State.dot => State.value}, # A list of values
    start_clock: State.tracker_state, # What clock range we recorded this from
    end_clock: State.tracker_state # What clock range we ended this recording from

  }

  defstruct dots: %{},
            cloud: MapSet.new,
            start_clock: %{},
            end_clock: %{}

  # TODO: Performance
  @doc "All the context "
  def is_contiguous?(%{end_clock: d1}, %{start_clock: d2}) do
    Clock.dominates_or_equal?(d1, d2)
  end

  def merge(%{cloud: c1, dots: d1, start_clock: sc1, end_clock: ec1}=delta1, %{cloud: c2, dots: d2, start_clock: sc2, end_clock: ec2}=delta2) do
    cond do
      is_contiguous?(delta1, delta2) ->
        new_cloud = MapSet.intersection(c1, c2)

        new_dots = for {dot, value} <- d1, Map.has_key?(d2, dot) or !MapSet.member?(c2, dot), into: %{}, do: {dot, value}
        # We already have everything that's in "both", so grab everything that isn't in our causal context
        new_dots = for {dot, value} <- d2, !Map.has_key?(d1, dot) and !MapSet.member?(c1, dot), into: new_dots, do: {dot, value}

        new_start = Clock.lowerbound(sc1, sc2)
        new_end = Clock.upperbound(ec1, ec2)

        %{delta1| dots: new_dots, cloud: new_cloud, start_clock: new_start, end_clock: new_end}
      true ->
        raise InvariantError, "Can only merge deltas that are contiguous for now"
    end
  end

  def size(%{cloud: c, dots: d}) do
    MapSet.size(c) + Map.size(d)
  end

end
