defmodule Phoenix.Tracker.VNode do
  @moduledoc false
  alias Phoenix.Tracker.VNode

  @type name :: String.t

  @type t :: %VNode{
    name: name,
    vsn: term,
    last_gossip_at: pos_integer,
    status: :up | :down | :permdown
  }

  defstruct name: nil,
            vsn: nil,
            last_gossip_at: nil,
            status: :up


  @type op_result :: {%{name => VNode.t}, previous_node :: VNode.t | nil, updated_node :: VNode.t}

  @doc """
  Returns a new VNode with a unique vsn.
  """
  @spec new(name) :: VNode.t
  def new(name) do
    %VNode{name: name, vsn: {now_ms(), System.unique_integer()}}
  end

  @spec ref(VNode.t) :: Phoenix.Tracker.State.noderef
  def ref(%VNode{name: name, vsn: vsn}), do: {name, vsn}

  @spec put_gossip(%{name => VNode.t}, VNode.t) :: op_result
  def put_gossip(vnodes, %VNode{name: name, vsn: vsn}) do
    case Map.fetch(vnodes, name) do
      :error ->
        new_vnode = touch_last_gossip(%VNode{name: name, vsn: vsn, status: :up})
        {Map.put(vnodes, name, new_vnode), nil, new_vnode}

      {:ok, %VNode{} = prev_vnode} ->
        updated_vnode = touch_last_gossip(%VNode{prev_vnode | vsn: vsn, status: :up})
        {Map.put(vnodes, name, updated_vnode), prev_vnode, updated_vnode}
    end
  end

  @spec detect_down(%{name => VNode.t}, VNode.t, pos_integer, pos_integer) :: op_result
  def detect_down(vnodes, vnode, temp_interval, perm_interval, now \\ now_ms()) do
    downtime = now - vnode.last_gossip_at
    cond do
      downtime > perm_interval -> {Map.delete(vnodes, vnode.name), vnode, permdown(vnode)}
      downtime > temp_interval ->
        updated_vnode = down(vnode)
        {Map.put(vnodes, vnode.name, updated_vnode), vnode, updated_vnode}
      true -> {vnodes, vnode, vnode}
    end
  end

  defp permdown(vnode), do: %VNode{vnode | status: :permdown}

  defp down(vnode), do: %VNode{vnode | status: :down}

  defp touch_last_gossip(vnode) do
    %VNode{vnode | last_gossip_at: now_ms()}
  end

  defp now_ms, do: :os.timestamp() |> time_to_ms()
  defp time_to_ms({mega, sec, micro}) do
    trunc(((mega * 1000000 + sec) * 1000) + (micro / 1000))
  end
end
