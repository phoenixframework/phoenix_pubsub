defmodule Phoenix.PubSub.PubSubTest do
  use ExUnit.Case, async: false # Bad idea to use async with CaptureIO
  import ExUnit.CaptureIO

  alias Phoenix.PubSub
  @pool_size 1

  defmodule Message do
    defstruct topic: nil, event: nil, payload: nil, ref: nil
  end

  defmodule Reply do
    defstruct topic: nil, status: nil, payload: nil, ref: nil
  end

  defmodule Broadcast do
    defstruct topic: nil, event: nil, payload: nil
  end

  def fastlane(subscribers, from, %Broadcast{event: event} = msg) do
    Enum.reduce(subscribers, %{}, fn
      {pid, _fastlanes}, cache when pid == from ->
        cache

      {pid, nil}, cache ->
        send(pid, msg)
        cache

      {pid, {fastlane_pid, serializer, event_intercepts}}, cache ->
        if event in event_intercepts do
          send(pid, msg)
          cache
        else
          case Map.fetch(cache, serializer) do
            {:ok, encoded_msg} ->
              send(fastlane_pid, encoded_msg)
              cache
            :error ->
              encoded_msg = serializer.fastlane!(msg)
              send(fastlane_pid, encoded_msg)
              Map.put(cache, serializer, encoded_msg)
          end
        end
    end)
  end

  def fastlane(subscribers, from, msg) do
    Enum.each(subscribers, fn
      {pid, _} when pid == from -> :noop
      {pid, _} -> send(pid, msg)
    end)
  end

  defmodule Serializer do
    def fastlane!(%Broadcast{} = msg) do
      send(Process.whereis(:phx_pubsub_test_subscriber), {:fastlaned, msg})
      %Message{
        topic: msg.topic,
        event: msg.event,
        payload: msg.payload
      }
    end

    def encode!(%Reply{} = reply) do
      %Message{
        topic: reply.topic,
        event: "phx_reply",
        ref: reply.ref,
        payload: %{status: reply.status, response: reply.payload}
      }
    end
    def encode!(%Message{} = msg) do
      msg
    end

    def decode!(message, _opts), do: message
  end


  setup_all do
    {:ok, _} =
      Phoenix.PubSub.PG2.start_link(__MODULE__, [pool_size: @pool_size, fastlane: __MODULE__])
    :ok
  end

  setup do
    Process.register(self(), :phx_pubsub_test_subscriber)
    :ok
  end

  def broadcast(error, _, _, _) do
    {:error, error}
  end

  test "broadcast!/3 and broadcast_from!/4 raises if broadcast fails" do
    :ets.new(FailedBroadcaster, [:named_table])
    :ets.insert(FailedBroadcaster, {:broadcast, __MODULE__, [:boom]})

    {:error, :boom} = PubSub.broadcast(FailedBroadcaster, "hello", %{})

    assert_raise PubSub.BroadcastError, fn ->
      PubSub.broadcast!(FailedBroadcaster, "topic", :ping)
    end

    assert_raise PubSub.BroadcastError, fn ->
      PubSub.broadcast_from!(FailedBroadcaster, self, "topic", :ping)
    end
  end

  test "fastlaning skips subscriber and sends directly to fastlane pid" do
    fastlane_pid = spawn_link fn -> :timer.sleep(:infinity) end

    PubSub.subscribe(__MODULE__, "topic1",
                     fastlane: {fastlane_pid, Serializer, ["intercepted"]})
    PubSub.subscribe(__MODULE__,  "topic1",
                     fastlane: {fastlane_pid, Serializer, ["intercepted"]})

    PubSub.broadcast(__MODULE__, "topic1", %Broadcast{event: "fastlaned", topic: "topic1", payload: %{}})

    fastlaned = %Message{event: "fastlaned", topic: "topic1", payload: %{}}
    refute_receive %Broadcast{}
    refute_receive %Message{}
    assert_receive {:fastlaned, %Broadcast{}}
    assert Process.info(fastlane_pid)[:messages] == [fastlaned, fastlaned]
    assert Process.info(self())[:messages] == [] # cached and fastlaned only sent once

    PubSub.broadcast(__MODULE__, "topic1", %Broadcast{event: "intercepted", topic: "topic1", payload: %{}})

    assert_receive %Broadcast{event: "intercepted", topic: "topic1", payload: %{}}
    assert Process.info(fastlane_pid)[:messages]
           == [fastlaned, fastlaned] # no additional messages received
  end

  test "deprecation warnings" do
    rando_pid = spawn_link fn -> :timer.sleep(:infinity) end
    expected_warning = ~r/warning.*pid.*subscribe.*deprecated/i

    assert Regex.match?(expected_warning,
             capture_io(:stderr, fn -> PubSub.subscribe(__MODULE__, rando_pid, "topic1") end)),
             "Subscribe with PID emits deprecation warning."
    assert Regex.match?(expected_warning,
             capture_io(:stderr, fn -> PubSub.unsubscribe(__MODULE__, rando_pid, "topic1") end)),
             "Unsubscribe with PID emits deprecation warning."
  end
end
