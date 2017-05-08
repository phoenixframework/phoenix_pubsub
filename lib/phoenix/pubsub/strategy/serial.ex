defmodule Phoenix.PubSub.Strategy.Serial do

  def broadcast(pool_size, fun) when is_function(fun, 1) do
    for shard <- 0..(pool_size - 1), do: fun.(shard)
    :ok
  end

end
