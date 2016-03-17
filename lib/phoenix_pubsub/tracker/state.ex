defmodule Phoenix.Tracker.State do
  @moduledoc """
  Provides an ORSWOT CRDT.
  """
  alias Phoenix.Tracker.State

  defstruct replica: nil,
            context: %{},
            cloud: MapSet.new(),
            tab: nil,
            mode: :unset,
            delta: :unset,
            replicas: %{},
            range: {0, 0}

  @doc """
  Creates a new set for the replica.

  ## Examples

      iex> Phoenix.Tracker.State.new(:replica1)
      %Phoenix.Tracker.State{...}

  """
  def new(replica) do
    reset_delta(%State{
      replica: replica,
      mode: :normal,
      tab: :ets.new(:tab, [:duplicate_bag]),
      replicas: %{replica => :up}})
  end

  @doc """
  Returns the causal context for the set.
  """
  def clocks(%State{replica: rep, context: ctx}), do: {rep, ctx}

  @doc """
  Adds a new element to the set.
  """
  def join(%State{} = state, pid, topic, key, meta \\ %{}) do
    add(state, pid, topic, key, meta)
  end

  @doc """
  Removes an element from the set.
  """
  def leave(%State{} = state, pid, topic, key) do
    remove(state, {{pid, topic}, {{key, :_}, :_}})
  end

  @doc """
  Removes all elements from the set for the given pid.
  """
  def leave(%State{} = state, pid) do
    remove(state, {{pid, :_}, :_})
  end

  @doc """
  Returns a list of elements in the set belonging to an online replica.
  """
  def online_list(%State{tab: tab} = state) do
    :ets.select(tab, Enum.map(up_replicas(state), fn replica ->
      {{:_, {:_, {replica, :_}}}, [], [:"$_"]}
    end))
  end

  @doc """
  Returns a list of elements for the topic who belong to an online replica.
  """
  def get_by_topic(%State{tab: tab} = state, topic) do
    :ets.select(tab, Enum.map(up_replicas(state), fn replica ->
      {{{:_, topic}, {:_, {replica, :_}}}, [], [:"$_"]}
    end))
  end

  @doc """
  Returns the element matching the pid, topic, and key.
  """
  def get_by_pid(%State{tab: tab}, pid, topic, key) do
    case :ets.match_object(tab, {{pid, topic}, {{key, :_}, :_}}) do
      [] -> nil
      [one] -> one
    end
  end

  @doc """
  Returns all elements for the pid.
  """
  def get_by_pid(%State{tab: tab}, pid) do
    :ets.match_object(tab, {{pid, :_}, :_})
  end

  @doc """
  Checks if set has a non-empty delta.
  """
  def has_delta?(%State{delta: %State{cloud: cloud}}) do
    MapSet.size(cloud) != 0
  end

  @doc """
  Resets the set's delta.
  """
  def reset_delta(%State{replica: replica} = state) do
    clock = clock(state)
    delta = %State{replica: replica,
                   tab: %{},
                   range: {clock, clock},
                   mode: :delta}
    %State{state | delta: delta}
  end

  @doc """
  Extracts the set's elements from ets into a mergable list.

  Used when merging two sets.
  """
  def extract(%State{tab: tab} = state) do
    map = foldl(tab, %{}, fn {{pid, topic}, {{key, meta}, tag}}, acc ->
      Map.put(acc, tag, {pid, topic, key, meta})
    end)
    {state, map}
  end

  @doc """
  Extracts the set's delta elements into a mergable list.

  Used when merging a delta into another set.
  """
  def extract_delta(%State{delta: delta}) do
    {delta, delta.tab}
  end

  @doc """
  Merges two sets, or a delta into a set.

  Returns a 3-tuple of the updated set, and the joiend and left elements.

  ## Examples

      iex> {s1, joined, left} =
           Phoenix.Tracker.State.merge(s1, Phoenix.Tracker.State.extract(s2))

      {%Phoenix.Tracker.State{}, [...], [...]}
  """
  def merge(%State{} = local, {%State{} = remote, remote_map}) do
    joins = accumulate_joins(local, remote_map)
    {cloud, delta, adds, leaves} = observe_removes(local, remote, remote_map, joins)
    true = :ets.delete_all_objects(local.tab)
    true = :ets.insert(local.tab, adds)
    ctx = Map.merge(local.context, remote.context, fn _, a, b -> max(a, b) end)
    new_state = compact(%State{local | context: ctx, cloud: cloud, delta: delta})

    {new_state, joins, leaves}
  end
  defp accumulate_joins(local, remote_map) do
    Enum.reduce(remote_map, [], fn {tag, {pid, topic, key, meta}}, adds ->
      if in?(local, tag) do
        adds
      else
        [{{pid, topic}, {{key, meta}, tag}} | adds]
      end
    end)
  end
  defp observe_removes(local, remote, remote_map, joins) do
    unioned_cloud = MapSet.union(local.cloud, remote.cloud)
    init = {unioned_cloud, local.delta, joins, []}

    foldl(local.tab, init, fn {_, {_, tag}} = el, {cloud, delta, adds, leaves} ->
      if in?(remote, tag) and not Map.has_key?(remote_map, tag) do
        {MapSet.delete(cloud, tag), remove_delta_tag(delta, tag), adds, [el | leaves]}
      else
        {cloud, delta, [el | adds], leaves}
      end
    end)
  end

  @doc """
  Marks a replica as up in the set and returns rejoined users.
  """
  def replica_up(%State{replicas: replicas} = state, replica) do
    {%State{state | replicas: Map.put(replicas, replica, :up)}, replica_users(state, replica), []}
  end

  @doc """
  Marks a replica as down in the set and returns left users.
  """
  def replica_down(%State{replicas: replicas} = state, replica) do
    {%State{state | replicas: Map.put(replicas, replica, :down)}, [], replica_users(state, replica)}
  end

  @doc """
  Removes all elements for replicas that are permanently gone.
  """
  # TODO: double check cleaning up cloud/delta for this case
  def remove_down_replicas(%State{context: ctx, tab: tab} = state, replica) do
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
    true = :ets.insert(tab, {{pid, topic}, {{key, meta}, tag(state)}})
    new_delta = %State{delta | tab: Map.put(delta.tab, tag(state), {pid, topic, key, meta})}
    %State{state | delta: new_delta}
  end

  defp remove(%State{tab: tab, cloud: cloud_before, delta: delta} = state, match_spec) do
    tags = Enum.map(:ets.match_object(tab, match_spec), fn {_, {{_, _}, tag}} -> tag end)
    true = :ets.match_delete(tab, match_spec)
    {pruned_cloud, new_delta} =
      Enum.reduce(tags, {cloud_before, delta}, fn tag, {cloud, delta} ->
        {MapSet.delete(cloud, tag), remove_delta_tag(delta, tag)}
      end)

    bump_clock(%State{state | cloud: pruned_cloud, delta: new_delta})
  end

  defp remove_delta_tag(%State{mode: :delta, tab: tab, cloud: cloud} = delta, tag) do
    %State{delta | cloud: MapSet.put(cloud, tag), tab: Map.delete(tab, tag)}
  end

  defp compact(%State{context: ctx, cloud: cloud} = state) do
    {new_ctx, new_cloud} = do_compact(ctx, Enum.sort(cloud))
    %State{state | context: new_ctx, cloud: new_cloud}
  end
  defp do_compact(ctx, cloud) do
    Enum.reduce(cloud, {ctx, MapSet.new()}, fn {replica, clock} = tag, {ctx_acc, cloud_acc} ->
      case {Map.get(ctx_acc, replica), clock} do
        {nil, 1} ->
          {Map.put(ctx_acc, replica, clock), cloud_acc}
        {nil, _} ->
          {ctx_acc, MapSet.put(cloud_acc, tag)}
        {ctx_clock, clock} when ctx_clock + 1 == clock ->
          {Map.put(ctx_acc, replica, clock), cloud_acc}
        {ctx_clock, clock} when ctx_clock >= clock ->
          {ctx_acc, cloud_acc}
        {_, _} ->
          {ctx_acc, MapSet.put(cloud_acc, tag)}
      end
    end)
  end

  defp in?(%State{context: ctx, cloud: cloud}, {replica, clock} = tag) do
    Map.get(ctx, replica, 0) >= clock or MapSet.member?(cloud, tag)
  end

  defp tag(%State{replica: rep} = state), do: {rep, clock(state)}

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

  defp up_replicas(%State{replicas: replicas})  do
    for {replica, :up} <- replicas, do: replica
  end

  defp foldl(tab, initial, func), do: :ets.foldl(func, initial, tab)

  defp replica_users(%State{tab: tab}, replica) do
    :ets.match_object(tab, {:_, {:_, {replica, :_}}})
  end
end
