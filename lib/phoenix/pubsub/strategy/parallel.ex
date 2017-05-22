defmodule Phoenix.PubSub.Strategy.Parallel do
  @moduledoc """
  Runs assigned tasks in parallel.

  This `Strategy` runs each task in a dedicated processes, using `Task.async`
  and `Task.await`.

  The call to `run` returns when all tasks have finished executing.

  """

  @behaviour Phoenix.PubSub.Strategy

  @spec run(non_neg_integer, (non_neg_integer -> any)) :: :ok
  def run(pool_size, fun) when is_function(fun, 1) do
    parent = self()
    for shard <- 0..(pool_size - 1) do
      Task.async(fn ->
        fun.(shard)
        Process.unlink(parent)
      end)
    end |> Enum.map(&Task.await(&1, :infinity))
    :ok
  end

end
