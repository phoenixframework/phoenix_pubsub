defmodule Mix.Tasks.Phoenix.PubSub.Bench do
  @moduledoc """
  Runs simple benchmarks for merge operations.

  ## Examples

      mix phoenix.pub_sub.bench --size 25000 --delta-size 1000
  """
  use Mix.Task
  alias Phoenix.Tracker.State


  def run(opts) do
    Mix.Task.run("app.start", [])
    {opts, [], []} = OptionParser.parse(opts, strict: [size: :integer,
                                                       delta_size: :integer])
    size       = opts[:size] || 100_000
    delta_size = opts[:delta_size] || 100

    {s1, s2} = time "Creating 2 #{size} element sets", fn ->
      s1 = Enum.reduce(1..size, State.new(:s1), fn i, acc ->
        State.join(acc, make_ref(), "topic#{i}", "user#{i}", %{name: i})
      end)

      s2 = Enum.reduce(1..size, State.new(:s2), fn i, acc ->
        State.join(acc, make_ref(), "topic#{i}", "user#{i}", %{name: i})
      end)

      {s1, s2}
    end

    {_, s2_vals} = extracted_s2 = time "extracting #{size} element set", fn ->
      State.extract(s2)
    end

    {s1, _, _} = time "merging 2 #{size} element sets", fn ->
      State.merge(s1, extracted_s2)
    end

    {s1, [], []} = time "merging again #{size} element sets", fn ->
      State.merge(s1, extracted_s2)
    end

    s1 = State.compact(s1)
    s2 = State.compact(s2)
    s2 = State.reset_delta(s2)

    {s2, _} = time "Creating delta with #{delta_size} joins and leaves", fn ->
      Enum.reduce(1..trunc(delta_size / 2), {s2, Enum.to_list(s2_vals)}, fn i, {acc, [prev_val | rest]} ->
        {_tag, {pid, topic, key, _meta}} = prev_val

        new_acc =
          acc
          |> State.join(make_ref(), "delta#{i}", "user#{i}", %{name: i})
          |> State.leave(pid, topic, key)
        {new_acc, rest}
      end)
    end


    {_s1, _, _} = time "Merging delta with #{delta_size} joins and leaves into #{size * 2} element set", fn ->
      State.merge(s1, s2.delta)
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
