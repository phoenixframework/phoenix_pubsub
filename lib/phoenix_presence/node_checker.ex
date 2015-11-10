defmodule Phoenix.Presence.NodeChecker do

  def node() do
    adapter().node()
  end

  def monitor_nodes(pid) do
    adapter().monitor_nodes(pid)
  end

  def demonitor_nodes(pid) do
    adapter().demonitor_nodes(pid)
  end

  def list do
    adapter().list()
  end

  def request_transfer(from, group_name, info) do
    adapter().request_transfer(from, group_name, info)
  end

  def transfer(reference, from_node, dest_node, group_name, payload) do
    adapter().transfer(reference, from_node, dest_node, group_name, payload)
  end

  defp adapter do
    Application.get_env(:phoenix_presence, :adapter, Phoenix.Presence.Adapters.Global)
  end
end
