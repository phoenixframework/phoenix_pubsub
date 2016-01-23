defmodule Phoenix.Tracker.State.Delta do

  @type t :: %__MODULE__{
    cloud: [Presence.dot], # The dots that we know are in this delta
    dots: %{Presence.dot => Presence.value}, # A list of values
    range: {Presence.clock, Presence.clock} # What clock range we recorded this from
  }

  defstruct dots: %{},
            cloud: [],
            range: {0,nil}

end
