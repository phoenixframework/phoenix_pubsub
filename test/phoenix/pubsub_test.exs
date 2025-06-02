defmodule Phoenix.PubSub.UnitTest do
  use ExUnit.Case, async: true

  describe "child_spec/1" do
    test "expects a name" do
      {:error, {{:EXIT, {exception, _}}, _}} = start_supervised({Phoenix.PubSub, []})

      assert Exception.message(exception) ==
               "the :name option is required when starting Phoenix.PubSub"
    end

    test "pool_size can't be smaller than broadcast_pool_size" do
      opts = [name: name(), pool_size: 1, broadcast_pool_size: 2]

      {:error, {{:shutdown, {:failed_to_start_child, Phoenix.PubSub.PG2, message}}, _}} =
        start_supervised({Phoenix.PubSub, opts})

      assert ^message = "the :pool_size option must be greater than or equal to the :broadcast_pool_size option"
    end

    defp name do
      :"#{__MODULE__}_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
    end
  end
end
