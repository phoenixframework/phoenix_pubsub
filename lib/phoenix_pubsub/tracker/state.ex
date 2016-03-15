defmodule Phoenix.Tracker.State do
  alias Phoenix.Tracker.State

  defstruct replica: nil,
            context: %{},
            cloud: MapSet.new(),
            tab: nil,
            mode: :unset,
            delta: :unset,
            nodes: %{},
            range: {0, 0}

  def new(replica) do
    reset_delta(%State{
      replica: replica,
      mode: :normal,
      tab: :ets.new(:tab, [:duplicate_bag]),
      nodes: %{replica => :up}})
  end

  def clocks(%State{replica: rep, context: ctx}), do: {rep, ctx}

  def join(%State{} = state, pid, topic, key, meta \\ %{}) do
    add(state, pid, topic, key, meta)
  end

  def leave(%State{} = state, pid, topic, key) do
    remove(state, {pid, {{topic, key, :_}, :_}})
  end

  def leave(%State{} = state, pid) do
    remove(state, {pid, :_})
  end

  def online_users(%State{tab: tab} = state) do
    :ets.select(tab, Enum.map(up_nodes(state), fn replica ->
      {{:_, {{:_, :"$1", :_}, {replica, :_}}}, [], [:"$1"]}
    end))
  end

  # for 1M entries ~ 400ms
  def get_by_topic(%State{tab: tab} = state, topic) do
    :ets.select(tab, Enum.map(up_nodes(state), fn replica ->
      {{:_, {{topic, :_, :_}, {replica, :_}}}, [], [:"$_"]}
    end))
  end

  def get_by_pid(%State{tab: tab}, pid, topic, key) do
    case :ets.match_object(tab, {pid, {{topic, key, :_}, :_}}) do
      [] -> nil
      [one] -> one
    end
  end
  def get_by_pid(%State{tab: tab}, pid) do
    :ets.match_object(tab, {pid, :_})
  end

  def node_up(%State{nodes: nodes} = state, replica) do
    {%State{state | nodes: Map.put(nodes, replica, :up)}, node_users(state, replica), []}
  end

  def node_down(%State{nodes: nodes} = state, replica) do
    {%State{state | nodes: Map.put(nodes, replica, :down)}, [], node_users(state, replica)}
  end

  defp node_users(%State{tab: tab}, replica) do
    :ets.match_object(tab, {:_, {:_, {replica, :_}}})
  end

  def remove_down_nodes(%State{context: ctx, tab: tab} = state, replica) do
    new_ctx = for {rep, clock} <- ctx, rep != replica, into: %{}, do: {rep, clock}
    true = :ets.match_delete(tab, {:_, {:_, {replica, :_}}})

    %State{state | context: new_ctx}
  end

  defp add(%State{} = state, pid, topic, key, meta) do
    state
    |> bump_clock()
    |> do_add(pid, topic, key, meta)
  end
  defp do_add(%State{tab: tab, delta: delta} = state, pid, topic, key, meta) do
    true = :ets.insert(tab, {pid, {{topic, key, meta}, id(state)}})
    new_delta = %State{delta | tab: Map.put(delta.tab, id(state), {pid, topic, key, meta})}
    %State{state | delta: new_delta}
  end

  defp remove(%State{tab: tab, cloud: cloud_before, delta: delta} = state, match_spec) do
    true = :ets.match_delete(tab, match_spec)
    fold = fn {_, {{_, _, _}, id}}, acc -> MapSet.put(acc, id) end
    pruned_cloud = :ets.foldl(fold, MapSet.new(), tab)
    new_delta = prune_delta(delta, cloud_before, pruned_cloud, [])

    bump_clock(%State{state | cloud: pruned_cloud, delta: new_delta})
  end

  defp prune_delta(%State{mode: :delta} = delta, cloud_before, pruned_cloud, adds) do
    removed_cloud = MapSet.difference(cloud_before, pruned_cloud)
    new_cloud = MapSet.union(delta.cloud, removed_cloud)
    pruned_tab = Map.drop(delta.tab, removed_cloud)
    new_tab = Enum.reduce(adds, pruned_tab, fn {pid, {data, id}}, acc ->
      Map.put(acc, id, {pid, data})
    end)

    %State{delta | cloud: new_cloud, tab: new_tab}
  end

  def has_delta?(%State{delta: %State{cloud: cloud}}) do
    MapSet.size(cloud) != 0
  end

  def reset_delta(%State{replica: replica} = state) do
    clock = clock(state)
    delta = %State{replica: replica,
                   tab: %{},
                   range: {clock, clock},
                   mode: :delta}
    %State{state | delta: delta}
  end

  def extract(%State{tab: tab} = state) do
    {state, :ets.tab2list(tab)}
  end

  def extract_delta(%State{delta: delta}) do
    normalized_list = for {id, {pid, topic, key, meta}} <- delta.tab do
      {pid, {{topic, key, meta}, id}}
    end

    {delta, normalized_list}
  end


  def merge(%State{cloud: cloud_before, delta: delta} = local, {%State{} = remote, remote_list}) do
    local_list = :ets.tab2list(local.tab)
    {new_cloud, joins, add_cloud} = Enum.reduce(remote_list, {cloud_before, [], MapSet.new()}, fn {_, {_, id}} = el, {cloud, adds, add_cloud} ->
      if in?(local, id) do
        {cloud, adds, MapSet.put(add_cloud, id)}
      else
        {MapSet.put(cloud, id), [el | adds], MapSet.put(add_cloud, id)}
      end
    end)
    {unioned_cloud, adds, removes} = Enum.reduce(local_list, {new_cloud, joins, []}, fn {_, {_, id}} = el, {cloud, adds, removes} ->
      if in?(remote, id) and not MapSet.member?(add_cloud, id) do
        {MapSet.delete(cloud, id), adds, [el | removes]}
      else
        {cloud, [el | adds], removes}
      end
    end)
    :ets.delete_all_objects(local.tab)
    :ets.insert(local.tab, adds)
    new_ctx = Map.merge(local.context, remote.context, fn _, a, b -> max(a, b) end)
    new_delta = prune_delta(delta, cloud_before, unioned_cloud, adds)
    new_state = compact(%State{local | context: new_ctx, cloud: unioned_cloud, delta: new_delta})

    {new_state, joins, removes}
  end

  defp compact(%State{context: ctx, cloud: cloud} = state) do
    {new_ctx, new_cloud} = compact_reduce(Enum.sort(cloud), ctx, [])
    %State{state | context: new_ctx, cloud: MapSet.new(new_cloud)}
  end
  defp compact_reduce([], ctx, cloud_acc) do
    {ctx, Enum.reverse(cloud_acc)}
  end
  defp compact_reduce([{replica, clock} = id | cloud], ctx, cloud_acc) do
    case {Map.get(ctx, replica), clock} do
      {nil, 1} -> # We can merge nil with 1 in the cloud
        compact_reduce(cloud, Map.put(ctx, replica, clock), cloud_acc)
      {nil, _} -> # Can't do anything with this
        compact_reduce(cloud, ctx, [id | cloud_acc])
      {ctx_clock, _} when ctx_clock + 1 == clock -> # Add to context, delete from cloud
        compact_reduce(cloud, Map.put(ctx, replica, clock), cloud_acc)
      {ctx_clock, _} when ctx_clock >= clock -> # Dominates # Delete from cloud by not accumulating.
        compact_reduce(cloud, ctx, cloud_acc)
      {_, _} -> # Can't do anything with this.
        compact_reduce(cloud, ctx, [id | cloud_acc])
    end
  end

  def in?(%State{context: ctx, cloud: cloud}, {replica, clock} = id) do
    Map.get(ctx, replica, 0) >= clock or MapSet.member?(cloud, id)
  end

  defp id(%State{replica: rep} = state), do: {rep, clock(state)}

  defp clock(%State{replica: rep, context: ctx}), do: Map.get(ctx, rep, 0)

  defp bump_clock(%State{mode: :normal, replica: rep, cloud: cloud, context: ctx, delta: delta} = state) do
    %State{cloud: delta_cloud, range: delta_range} = delta
    new_clock = clock(state) + 1

    %State{state |
           cloud: MapSet.put(cloud, {rep, new_clock}),
           context: Map.put(ctx, rep, new_clock),
           delta: %State{delta |
                         cloud: MapSet.put(delta_cloud, {rep, new_clock}),
                         range: put_elem(delta_range, 1, new_clock)}}
  end

  defp up_nodes(%State{nodes: nodes})  do
    for {replica, :up} <- nodes, do: replica
  end
end
