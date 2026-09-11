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

  describe ":sender" do
    defmodule TestSender do
      @behaviour Phoenix.PubSub.Sender

      @impl true
      def send(pid, meta, message, state) do
        # state doubles as a call counter so tests can observe accumulation
        count = (state || 0) + 1
        Kernel.send(pid, {:sent, meta, message, state})
        count
      end
    end

    defp start_pubsub!(opts \\ []) do
      name = :"ps_sender_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PubSub, [name: name] ++ opts})
      name
    end

    defp subscribe_from_new_process(name, sender) do
      parent = self()

      spawn_link(fn ->
        PubSub.subscribe(name, "topic", sender: sender)
        send(parent, :subscribed)
        receive do: ({:sent, _, _, state} -> send(parent, {:state, state}))
      end)

      assert_receive :subscribed
    end

    test "invokes the sender instead of a plain send" do
      name = start_pubsub!()

      PubSub.subscribe(name, "topic", sender: {TestSender, {:custom, "topic"}})
      PubSub.broadcast(name, "topic", :hello)

      assert_receive {:sent, {:custom, "topic"}, :hello, nil}
      refute_received :hello
    end

    test "delivers exactly once per subscription" do
      name = start_pubsub!()

      PubSub.subscribe(name, "topic", sender: {TestSender, :meta})
      PubSub.broadcast(name, "topic", :hello)

      assert_receive {:sent, :meta, :hello, _}
      refute_received {:sent, :meta, :hello, _}
    end

    test "plain subscribers are delivered exactly once" do
      name = start_pubsub!()

      PubSub.subscribe(name, "topic")
      PubSub.broadcast(name, "topic", :hello)

      assert_receive :hello
      refute_received :hello
    end

    test "state accumulates across subscriptions within a registry partition" do
      name = start_pubsub!(registry_size: 1)
      for _ <- 1..3, do: subscribe_from_new_process(name, {TestSender, :meta})

      PubSub.broadcast(name, "topic", :hello)

      states =
        for _ <- 1..3 do
          assert_receive {:state, state}
          state
        end

      # first call gets nil, each subsequent call sees the previous return value
      assert MapSet.new(states) == MapSet.new([nil, 1, 2])
    end

    test "state does not carry across registry partitions" do
      # Registry.dispatch/3 invokes the dispatch function once per partition
      # (concurrently), so each partition starts its accumulator over at nil.
      name = start_pubsub!(pool_size: 2, registry_size: 2)
      for _ <- 1..20, do: subscribe_from_new_process(name, {TestSender, :meta})

      PubSub.broadcast(name, "topic", :hello)

      states =
        for _ <- 1..20 do
          assert_receive {:state, state}
          state
        end

      # more than one partition holds subscribers, so nil is seen more than once
      assert Enum.count(states, &is_nil/1) == 2
    end

    test "senders and plain subscribers coexist on one topic" do
      name = start_pubsub!()
      parent = self()

      spawn_link(fn ->
        PubSub.subscribe(name, "topic")
        send(parent, :subscribed)
        receive do: (msg -> send(parent, {:plain, msg}))
      end)

      assert_receive :subscribed
      PubSub.subscribe(name, "topic", sender: {TestSender, :meta})
      PubSub.broadcast(name, "topic", :hello)

      assert_receive {:sent, :meta, :hello, nil}
      assert_receive {:plain, :hello}
    end

    test "broadcast_from/4 skips the sending process" do
      name = start_pubsub!()

      PubSub.subscribe(name, "topic", sender: {TestSender, :meta})
      PubSub.broadcast_from(name, self(), "topic", :hello)

      refute_received {:sent, :meta, :hello, _}
    end

    test "local_broadcast/3 invokes the sender" do
      name = start_pubsub!()

      PubSub.subscribe(name, "topic", sender: {TestSender, :meta})
      PubSub.local_broadcast(name, "topic", :hello)

      assert_receive {:sent, :meta, :hello, nil}
    end

    test "unsubscribe removes the sender subscription" do
      name = start_pubsub!()

      PubSub.subscribe(name, "topic", sender: {TestSender, :meta})
      PubSub.unsubscribe(name, "topic")
      PubSub.broadcast(name, "topic", :hello)

      refute_received {:sent, :meta, :hello, _}
    end
  end

  describe "group_by" do
    test "defaults to :pid, delivering one message per subscription" do
      name = :"ps_default_group_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PubSub, name: name})

      assert :ok = PubSub.subscribe(name, "topic")
      assert :ok = PubSub.subscribe(name, "topic")

      PubSub.broadcast(name, "topic", :hello)

      assert_receive :hello
      assert_receive :hello
    end

    test ":pid delivers one message per subscription" do
      name = :"ps_pid_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PubSub, name: name, group_by: :pid})

      assert :ok = PubSub.subscribe(name, "topic")
      assert :ok = PubSub.subscribe(name, "topic")

      PubSub.broadcast(name, "topic", :hello)

      assert_receive :hello
      assert_receive :hello
    end

    test "raises ArgumentError on an invalid value" do
      name = :"ps_bad_#{:erlang.unique_integer([:positive])}"

      {:error, {{%ArgumentError{} = exception, _stacktrace}, _child_info}} =
        start_supervised({PubSub, name: name, group_by: :bogus})

      assert Exception.message(exception) =~ "invalid :group_by option"
      assert Exception.message(exception) =~ ":bogus"
    end

    if Version.match?(System.version(), ">= 1.19.0") do
      test ":key delivers one message per subscription (Elixir 1.19+)" do
        name = :"ps_key_#{:erlang.unique_integer([:positive])}"
        start_supervised!({PubSub, name: name, group_by: :key})

        assert :ok = PubSub.subscribe(name, "topic")
        assert :ok = PubSub.subscribe(name, "topic")

        PubSub.broadcast(name, "topic", :hello)

        assert_receive :hello
        assert_receive :hello
      end
    end
  end
end
