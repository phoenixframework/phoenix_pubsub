defmodule Phoenix.PubSub.UnitTest do
  use ExUnit.Case, async: true

  describe "child_spec/1" do
    test "expects a name" do
      {:error, {{:EXIT, {exception, _}}, _}} = start_supervised({Phoenix.PubSub, []})

      assert Exception.message(exception) ==
               "the :name option is required when starting Phoenix.PubSub"
    end
  end
end
