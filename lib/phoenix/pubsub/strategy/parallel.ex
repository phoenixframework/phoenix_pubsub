defmodule Phoenix.PubSub.Strategy.Parallel do

  def broadcast(pool_size, fun) when is_function(fun, 1) do
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
