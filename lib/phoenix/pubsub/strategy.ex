defmodule Phoenix.PubSub.Strategy do
  @moduledoc """
  Executes a number of tasks.

  A `Strategy` implements the `run` callback, which takes a number `n`
  and a fun, and applies the numbers `1..n` to the fun.

  The particulars of how this is enacted are implementation-dependent.
  """

  @callback run(non_neg_integer, (non_neg_integer -> any)) :: :ok

end
