defmodule Phoenix.PubSub.Strategy.Serial do
  @moduledoc """
  Runs assigned tasks serially.

  This `Strategy` runs assigned tasks one after another,
  in the context of the calling process.

  """

  @behaviour Phoenix.PubSub.Strategy

  @spec run(non_neg_integer, (non_neg_integer -> any)) :: :ok
  def run(pool_size, fun) when is_function(fun, 1) do
    for shard <- 0..(pool_size - 1), do: fun.(shard)
    :ok
  end

end
