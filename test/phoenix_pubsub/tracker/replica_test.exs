defmodule Phoenix.Tracker.ReplicaTest do
  use ExUnit.Case, async: true
  alias Phoenix.Tracker.{Replica}

  test "new/1 returns a new Replica with unique vsn" do
    replica1 = Replica.new("name")
    assert replica1.name == "name"
    assert replica1.vsn

    replica2 = Replica.new("name")
    assert replica2.name == "name"
    assert replica2.vsn != replica1.vsn
  end

  test "ref/1 returns a tuple of {name, vsn}" do
    assert Replica.ref(%Replica{name: "name", vsn: {1, 1}}) == {"name", {1, 1}}
  end

  test "put_heartbeat/2 with no previously tracked name" do
    new_node = Replica.new("new")
    assert {replicas, nil, added_replica} = Replica.put_heartbeat(%{}, Replica.ref(new_node))
    assert replicas["new"] == added_replica
    assert added_replica.name == new_node.name
    assert added_replica.vsn == new_node.vsn
    assert added_replica.last_heartbeat_at
    assert added_replica.status == :up
  end

  test "put_heartbeat/2 with previously tracked name" do
    for status <- [:up, :down] do
      existing_node = Replica.new("existing") |> Map.put(:status, status)
      assert {replicas, ^existing_node, updated_node} =
            Replica.put_heartbeat(%{ "existing" => existing_node}, Replica.ref(existing_node))

      assert replicas["existing"] == updated_node
      assert updated_node.name == existing_node.name
      assert updated_node.vsn == existing_node.vsn
      assert updated_node.last_heartbeat_at != existing_node.last_heartbeat_at
      assert updated_node.last_heartbeat_at
      assert updated_node.status == :up
    end
  end

  test "detect_down/4 with temporarily downed node" do
    {replicas, nil, tempdown_node} = Replica.put_heartbeat(%{}, Replica.ref(Replica.new("tempdown")))
    assert {replicas, ^tempdown_node, updated_tempdown} =
           Replica.detect_down(replicas, tempdown_node, 5, 10, tempdown_node.last_heartbeat_at + 6)

    assert Map.fetch(replicas, "tempdown") == {:ok, updated_tempdown}
    assert updated_tempdown.name == "tempdown"
    assert updated_tempdown.vsn == tempdown_node.vsn
    assert updated_tempdown.status == :down
  end

  test "detect_down/4 with permanently downed node removes from replicas map" do
    {replicas, nil, tempdown_node} = Replica.put_heartbeat(%{}, Replica.ref(Replica.new("tempdown")))
    assert {replicas, ^tempdown_node, updated_tempdown} =
           Replica.detect_down(replicas, tempdown_node, 5, 10, tempdown_node.last_heartbeat_at + 11)

    assert Map.fetch(replicas, "tempdown") == :error
    assert updated_tempdown.name == "tempdown"
    assert updated_tempdown.vsn == tempdown_node.vsn
    assert updated_tempdown.status == :permdown
  end

  test "detect_down/4 with up node" do
    {replicas, nil, up_node} = Replica.put_heartbeat(%{}, Replica.ref(Replica.new("up")))
    assert {replicas, ^up_node, ^up_node} =
           Replica.detect_down(replicas, up_node, 5, 10, up_node.last_heartbeat_at)

    assert Map.fetch(replicas, "up") == {:ok, up_node}
    assert up_node.status == :up
  end
end
