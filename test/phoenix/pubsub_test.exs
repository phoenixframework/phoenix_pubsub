defmodule Phoenix.PubSub.UnitTest do
  use ExUnit.Case, async: true

  alias Phoenix.PubSub

  describe "child_spec/1" do
    test "expects a name" do
      {:error, {{:EXIT, {exception, _}}, _}} = start_supervised({PubSub, []})

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

  describe "default dispatcher" do
    defmodule TestDispatcher do
      def dispatch(entries, :none, message) do
        for {pid, _} <- entries do
          send(pid, {:custom_dispatched, message})
        end

        :ok
      end

      def dispatch(entries, from, message) do
        for {pid, _} <- entries, pid != from do
          send(pid, {:custom_dispatched, message})
        end

        :ok
      end
    end

    test "defaults to Phoenix.PubSub when no dispatcher configured" do
      name = :"ps_default_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PubSub, name: name})

      PubSub.subscribe(name, "topic")
      PubSub.broadcast(name, "topic", :hello)
      assert_receive :hello
    end

    test "uses configured dispatcher for broadcast/3" do
      name = :"ps_custom_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PubSub, name: name, dispatcher: TestDispatcher})

      PubSub.subscribe(name, "topic")
      PubSub.broadcast(name, "topic", :hello)
      assert_receive {:custom_dispatched, :hello}
      refute_received :hello
    end

    test "uses configured dispatcher for local_broadcast/3" do
      name = :"ps_local_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PubSub, name: name, dispatcher: TestDispatcher})

      PubSub.subscribe(name, "topic")
      PubSub.local_broadcast(name, "topic", :hello)
      assert_receive {:custom_dispatched, :hello}
    end

    test "uses configured dispatcher for broadcast_from/4" do
      name = :"ps_from_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PubSub, name: name, dispatcher: TestDispatcher})

      PubSub.subscribe(name, "topic")
      other = spawn(fn -> Process.sleep(:infinity) end)
      PubSub.broadcast_from(name, other, "topic", :hello)
      assert_receive {:custom_dispatched, :hello}
    end

    test "explicit dispatcher overrides the configured default" do
      name = :"ps_override_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PubSub, name: name, dispatcher: TestDispatcher})

      PubSub.subscribe(name, "topic")
      # Pass Phoenix.PubSub explicitly to override the configured TestDispatcher
      PubSub.broadcast(name, "topic", :hello, PubSub)
      assert_receive :hello
      refute_received {:custom_dispatched, :hello}
    end

    test "bang variants use configured dispatcher" do
      name = :"ps_bang_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PubSub, name: name, dispatcher: TestDispatcher})

      PubSub.subscribe(name, "topic")
      PubSub.broadcast!(name, "topic", :hello)
      assert_receive {:custom_dispatched, :hello}
    end
  end
end
