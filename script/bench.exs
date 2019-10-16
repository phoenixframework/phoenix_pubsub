defmodule Bench do
  @moduledoc """
  Runs simple benchmarks for merge operations.

  ## Examples

      mix run script/bench.exs --size 25000 --delta-size 1000

  """

  alias Phoenix.Tracker.State

  def run(opts) do
    {opts, [], []} = OptionParser.parse(opts, strict: [size: :integer,
                                                       delta_size: :integer])
    size       = opts[:size] || 100_000
    delta_size = opts[:delta_size] || 100
    topic_size = trunc(size / 10)

    {s1, s2} = time "Creating 2 #{size} element sets", fn ->
      s1 = Enum.reduce(1..size, State.new(:s1), fn i, acc ->

        State.join(acc, make_ref(), "topic#{:erlang.phash2(i, topic_size)}", "user#{i}", %{name: i})
      end)

      s2 = Enum.reduce(1..size, State.new(:s2), fn i, acc ->
        State.join(acc, make_ref(), "topic#{i}", "user#{i}", %{name: i})
      end)

      {s1, s2}
    end
    user = make_ref()
    s1 = State.join(s1, user, "topic100", "user100", %{name: 100})

    {_, s2_vals} = extracted_s2 = time "extracting #{size} element set", fn ->
      State.extract(s2, :s2, s2.context)
    end

    {s1, _, _} = time "merging 2 #{size} element sets", fn ->
      State.merge(s1, extracted_s2)
    end

    {s1, [], []} = time "merging again #{size} element sets", fn ->
      State.merge(s1, extracted_s2)
    end

    time "get_by_topic for 1000 members of #{size * 2} element set", fn ->
      State.get_by_topic(s1, "topic10")
    end

    [{{topic, pid, key}, _meta, _tag} | _] = time "get_by_pid/2 for #{size * 2} element set", fn ->
      State.get_by_pid(s1, user)
    end

    time "get_by_pid/4 for #{size * 2} element set", fn ->
      State.get_by_pid(s1, pid, topic, key) || raise("none")
    end

    s1 = State.compact(s1)
    s2 = State.compact(s2)
    s2 = State.reset_delta(s2)

    {s2, _} = time "Creating delta with #{delta_size} joins and leaves", fn ->
      Enum.reduce(1..trunc(delta_size / 2), {s2, Enum.to_list(s2_vals)}, fn
        i, {acc, [prev_val | rest]} ->
          {_tag, {pid, topic, key, _meta}} = prev_val

          new_acc =
            acc
            |> State.join(make_ref(), "delta#{i}", "user#{i}", %{name: i})
            |> State.leave(pid, topic, key)
          {new_acc, rest}
        
        _, result ->
          result
      end)
    end

    {s1, _, _} = time "Merging delta with #{delta_size} joins and leaves into #{size * 2} element set", fn ->
      State.merge(s1, s2.delta)
    end

    {s1, _, _} = time "replica_down from #{size *2} replica with downed holding #{size} elements", fn ->
      State.replica_down(s1, s2.replica)
    end

    _s1 = time "remove_down_replicas from #{size *2} replica with downed holding #{size} elements", fn ->
      State.remove_down_replicas(s1, s2.replica)
    end
  end

  defp time(log, func) do
    IO.puts "\n>> #{log}..."
    {micro, result} = :timer.tc(func)
    ms = Float.round(micro / 1000, 2)
    sec = Float.round(ms / 1000, 2)
    IO.puts "   = #{ms}ms    #{sec}s"

    result
  end
end

Bench.run(System.argv())