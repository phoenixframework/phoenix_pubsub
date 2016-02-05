defmodule Phoenix.Tracker.State.Delta do

  @type t :: %__MODULE__{
    cloud: MapSet.t, # The dots that we know are in this delta
    dots: %{Presence.dot => Presence.value}, # A list of values
  }

  defstruct dots: %{},
            cloud: MapSet.new

  def merge(%{dots: dots1, cloud: cloud1}=set1, %{dots: dots2, cloud: cloud2}) do
    # We keep values for which there is a dot in the other person's dots, or there's *no* causal link in the other cloud
    new_dots = for {dot, value} <- dots1, Map.has_key?(dots2, dot) or !MapSet.member?(cloud2, dot), into: %{}, do: {dot, value}
    # We already have everything that's in "both", so grab everything that isn't in our causal context
    new_dots = for {dot, value} <- dots2, !Map.has_key?(dots1, dot) and !MapSet.member?(cloud1, dot), into: new_dots, do: {dot, value}
    %{set1| cloud: MapSet.intersection(cloud1, cloud2), dots: new_dots}
  end

end
