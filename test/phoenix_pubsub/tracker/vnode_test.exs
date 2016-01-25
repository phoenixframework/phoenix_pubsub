defmodule Phoenix.Tracker.VNodeTest do
  use ExUnit.Case, async: true
  alias Phoenix.Tracker.{VNode}

  test "new/1 returns a new VNode with unique vsn" do
    vnode1 = VNode.new("name")
    assert vnode1.name == "name"
    assert vnode1.vsn

    vnode2 = VNode.new("name")
    assert vnode2.name == "name"
    assert vnode2.vsn != vnode1.vsn
  end

  test "ref/1 returns a tuple of {name, vsn}" do
    assert VNode.ref(%VNode{name: "name", vsn: {1, 1}}) == {"name", {1, 1}}
  end

  test "put_gossip/2 with no previously tracked name" do
    new_node = VNode.new("new")
    assert {vnodes, nil, added_vnode} = VNode.put_gossip(%{}, new_node)
    assert vnodes["new"] == added_vnode
    assert added_vnode.name == new_node.name
    assert added_vnode.vsn == new_node.vsn
    assert added_vnode.last_gossip_at
    assert added_vnode.status == :up
  end

  test "put_gossip/2 with previously tracked name" do
    for status <- [:up, :down] do
      existing_node = VNode.new("existing") |> Map.put(:status, status)
      assert {vnodes, ^existing_node, updated_node} =
            VNode.put_gossip(%{ "existing" => existing_node}, existing_node)

      assert vnodes["existing"] == updated_node
      assert updated_node.name == existing_node.name
      assert updated_node.vsn == existing_node.vsn
      assert updated_node.last_gossip_at != existing_node.last_gossip_at
      assert updated_node.last_gossip_at
      assert updated_node.status == :up
    end
  end

  test "detect_down/4 with temporarily downed node" do
    {vnodes, nil, tempdown_node} = VNode.put_gossip(%{}, VNode.new("tempdown"))
    assert {vnodes, ^tempdown_node, updated_tempdown} =
           VNode.detect_down(vnodes, tempdown_node, 5, 10, tempdown_node.last_gossip_at + 6)

    assert Map.fetch(vnodes, "tempdown") == {:ok, updated_tempdown}
    assert updated_tempdown.name == "tempdown"
    assert updated_tempdown.vsn == tempdown_node.vsn
    assert updated_tempdown.status == :down
  end

  test "detect_down/4 with permanently downed node removes from vnodes map" do
    {vnodes, nil, tempdown_node} = VNode.put_gossip(%{}, VNode.new("tempdown"))
    assert {vnodes, ^tempdown_node, updated_tempdown} =
           VNode.detect_down(vnodes, tempdown_node, 5, 10, tempdown_node.last_gossip_at + 11)

    assert Map.fetch(vnodes, "tempdown") == :error
    assert updated_tempdown.name == "tempdown"
    assert updated_tempdown.vsn == tempdown_node.vsn
    assert updated_tempdown.status == :permdown
  end

  test "detect_down/4 with up node" do
    {vnodes, nil, up_node} = VNode.put_gossip(%{}, VNode.new("up"))
    assert {vnodes, ^up_node, ^up_node} =
           VNode.detect_down(vnodes, up_node, 5, 10, up_node.last_gossip_at)

    assert Map.fetch(vnodes, "up") == {:ok, up_node}
    assert up_node.status == :up
  end
end
