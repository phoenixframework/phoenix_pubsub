defmodule Mix.Tasks.Phoenix.PubSub.Bench do
  use Mix.Task
  alias Phoenix.Tracker.State
  # alias Phoenix.Tracker.State.ShardedState, as: State

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

    {s1, _, _} = time "merging 2 #{size} element sets", fn ->
      State.merge(s1, State.extract(s2))
    end

    {s1, [], []} = time "merging again #{size} element sets", fn ->
      State.merge(s1, State.extract(s2))
    end

    s1 = State.reset_delta(s1)

    s1 = time "Creating delta with #{delta_size} elements", fn ->
      Enum.reduce(1..delta_size, s1, fn i, acc ->
        State.join(acc, make_ref(), "delta#{i}", "user#{i}", %{name: i})
      end)
    end

    {s2, _, _} = time "Merging delta with #{delta_size} elements into #{size} element set", fn ->
      State.merge(s2, State.delta(s1))
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
