defmodule Phoenix.TrackerTest do
  use ExUnit.Case, async: true

  defmodule MyTracker do
    use Phoenix.Tracker
    def init(state), do: {:ok, state}
    def handle_diff(_diff, state), do: {:ok, state}
  end

  test "generates child spec" do
    assert MyTracker.child_spec([]) == %{
             id: Phoenix.TrackerTest.MyTracker,
             start: {Phoenix.TrackerTest.MyTracker, :start_link, [[]]},
             type: :supervisor
           }
  end
end
