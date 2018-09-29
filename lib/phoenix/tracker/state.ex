defmodule Phoenix.Tracker.State do
  @moduledoc """
  Provides an ORSWOT CRDT.
  """
  alias Phoenix.Tracker.{State, Clock}

  @type name       :: term
  @type topic      :: String.t
  @type key        :: term
  @type meta       :: map
  @type ets_id     :: :ets.tid
  @type clock      :: pos_integer
  @type tag        :: {name, clock}
  @type cloud      :: MapSet.t
  @type clouds     :: %{name => cloud}
  @type context    :: %{name => clock}
  @type values     :: ets_id | :extracted | %{tag => {pid, topic, key, meta}}
  @type value      :: {{topic, pid, key}, meta, tag}
  @type key_meta   :: {key, meta}
  @type delta      :: %State{mode: :delta}
  @type pid_lookup :: {pid, topic, key}

  @type t :: %State{
    replica:  name,
    context:  context,
    clouds:   clouds,
    values:   values,
    pids:     ets_id,
    mode:     :unset | :delta | :normal,
    delta:    :unset | delta,
    replicas: %{name => :up | :down},
    range:    {context, context}
  }

  defstruct replica: nil,
            context: %{},
            clouds: %{},
            values: nil,
            pids: nil,
            mode: :unset,
            delta: :unset,
            replicas: %{},
            range: {%{}, %{}}

  @compile {:inline, tag: 1, clock: 1, put_tag: 2, delete_tag: 2, remove_delta_tag: 2}

  @doc """
  Creates a new set for the replica.

  ## Examples

      iex> Phoenix.Tracker.State.new(:replica1)
      %Phoenix.Tracker.State{...}

  """
  @spec new(name, atom) :: t
  def new(replica, shard_name) do
    reset_delta(%State{
      replica: replica,
      context: %{replica => 0},
      mode: :normal,
      values: :ets.new(shard_name, [:named_table, :protected, :ordered_set]),
      pids: :ets.new(:pids, [:duplicate_bag]),
      replicas: %{replica => :up}})
  end

  @doc """
  Returns the causal context for the set.
  """
  @spec clocks(t) :: {name, context}
  def clocks(%State{replica: rep, context: ctx}), do: {rep, ctx}

  @doc """
  Adds a new element to the set.
  """
  @spec join(t, pid, topic, key, meta) :: t
  def join(%State{} = state, pid, topic, key, meta \\ %{}) do
    add(state, pid, topic, key, meta)
  end

  @doc """
  Removes an element from the set.
  """
  @spec leave(t, pid, topic, key) :: t
  def leave(%State{pids: pids} = state, pid, topic, key) do
    pids
    |> :ets.match_object({pid, topic, key})
    |> case do
      [{^pid, ^topic, ^key}] -> remove(state, pid, topic, key)
      [] -> state
    end
  end

  @doc """
  Removes all elements from the set for the given pid.
  """
  @spec leave(t, pid) :: t
  def leave(%State{pids: pids} = state, pid) do
    pids
    |> :ets.lookup(pid)
    |> Enum.reduce(state, fn {^pid, topic, key}, acc ->
      remove(acc, pid, topic, key)
    end)
  end

  @doc """
  Returns a list of elements in the set belonging to an online replica.
  """
  @spec online_list(t) :: [value]
  def online_list(%State{values: values} = state) do
    replicas = down_replicas(state)
    :ets.select(values, [{ {:_, :_, {:"$1", :_}},
      not_in(:"$1", replicas), [:"$_"]}])
  end

  @doc """
  Returns a list of elements for the topic who belong to an online replica.
  """
  @spec get_by_topic(t, topic) :: [key_meta]
  def get_by_topic(%State{values: values} = state, topic) do
    tracked_values(values, topic, down_replicas(state))
  end

  @doc """
  Returns a list of elements for the topic who belong to an online replica.
  """
  @spec get_by_key(t, topic, key) :: [key_meta]
  def get_by_key(%State{values: values} = state, topic, key) do
    case tracked_key(values, topic, key, down_replicas(state)) do
      [] -> []
      [_|_] = metas -> metas
    end
  end

  @doc """
  Performs table lookup for tracked elements in the topic.

  Filters out those present on downed replicas.
  """
  def tracked_values(table, topic, down_replicas) do
    :ets.select(table,
      [{{{topic, :_, :"$1"}, :"$2", {:"$3", :_}},
        not_in(:"$3", down_replicas),
        [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Performs table lookup for tracked key in the topic.

  Filters out those present on downed replicas.
  """
  def tracked_key(table, topic, key, down_replicas) do
    :ets.select(table,
      [{{{topic, :"$1", key}, :"$2", {:"$3", :_}},
        not_in(:"$3", down_replicas),
        [{{:"$1", :"$2"}}]}])
  end

  defp not_in(_pos, []), do: []
  defp not_in(pos, replicas), do: [not: ors(pos, replicas)]
  defp ors(pos, [rep]), do: {:"=:=", pos, {rep}}
  defp ors(pos, [rep | rest]), do: {:or, {:"=:=", pos, {rep}}, ors(pos, rest)}

  @doc """
  Returns the element matching the pid, topic, and key.
  """
  @spec get_by_pid(t, pid, topic, key) :: value | nil
  def get_by_pid(%State{values: values}, pid, topic, key) do
    case :ets.lookup(values, {topic, pid, key}) do
      [] -> nil
      [one] -> one
    end
  end

  @doc """
  Returns all elements for the pid.
  """
  @spec get_by_pid(t, pid) :: [value]
  def get_by_pid(%State{pids: pids, values: values}, pid) do
    case :ets.lookup(pids, pid) do
      [] -> []
      matches ->
        :ets.select(values, Enum.map(matches, fn {^pid, topic, key} ->
          {{{topic, pid, key}, :_, :_}, [], [:"$_"]}
        end))
    end
  end

  @doc """
  Checks if set has a non-empty delta.
  """
  @spec has_delta?(t) :: boolean
  def has_delta?(%State{delta: %State{clouds: clouds}}) do
    Enum.find(clouds, fn {_name, cloud} -> MapSet.size(cloud) != 0 end)
  end

  @doc """
  Resets the set's delta.
  """
  @spec reset_delta(t) :: t
  def reset_delta(%State{context: ctx, replica: replica} = state) do
    delta_ctx = Map.take(ctx, [replica])
    delta = %State{replica: replica,
                   values: %{},
                   range: {delta_ctx, delta_ctx},
                   mode: :delta}
    %State{state | delta: delta}
  end

  @doc """
  Extracts the set's elements from ets into a mergeable list.

  Used when merging two sets.
  """

  @spec extract(t, remote_ref :: name, context) :: t | {t, values}
  def extract(%State{mode: :delta, values: values, clouds: clouds} = state, remote_ref, remote_context) do
    {start_ctx, end_ctx} = state.range
    known_keys = Map.keys(remote_context)
    pruned_clouds = Map.take(clouds, known_keys)
    pruned_start = Map.take(start_ctx, known_keys)
    pruned_end = Map.take(end_ctx, known_keys)
    map = Enum.reduce(values, [], fn
      {{^remote_ref, _clock}, _data}, acc -> acc
      {{replica, _clock} = tag, data}, acc ->
        if Map.has_key?(remote_context, replica) do
          [{tag, data} | acc]
        else
          acc
        end
    end) |> :maps.from_list()

    %State{state | values: map, clouds: pruned_clouds, range: {pruned_start, pruned_end}}
  end
  def extract(%State{mode: :normal, values: values, clouds: clouds} = state, remote_ref, remote_context) do
    known_keys = Map.keys(remote_context)
    pruned_clouds = Map.take(clouds, known_keys)
    pruned_context = Map.take(state.context, known_keys)
    # fn {{topic, pid, key}, meta, {replica, clock}} when replica !== remote_ref ->
    #  {{replica, clock}, {pid, topic, key, meta}}
    # end
    ms = [{
      {{:"$1", :"$2", :"$3"}, :"$4", {:"$5", :"$6"}},
      [{:"=/=", :"$5", {:const, remote_ref}}],
      [{{{{:"$5", :"$6"}}, {{:"$2", :"$1", :"$3", :"$4"}}}}]
    }]
    data =
      foldl(values, [], ms, fn {{replica, _} = tag, data}, acc ->
        if match?(%{^replica => _}, remote_context) do
          [{tag, data} | acc]
        else
          acc
        end
      end)

    {%State{state |
        clouds: pruned_clouds,
        context: pruned_context,
        pids: nil,
        values: nil,
        delta: :unset}, Map.new(data)}
  end

  @doc """
  Merges two sets, or a delta into a set.

  Returns a 3-tuple of the updated set, and the joined and left elements.

  ## Examples

      iex> {s1, joined, left} =
           Phoenix.Tracker.State.merge(s1, Phoenix.Tracker.State.extract(s2))

      {%Phoenix.Tracker.State{}, [...], [...]}
  """
  @spec merge(local :: t, {remote :: t, values} | delta) :: {new_local :: t, joins :: [value], leaves :: [value]}
  def merge(%State{} = local, %State{mode: :delta, values: remote_map} = remote) do
    merge(local, remote, remote_map)
  end
  def merge(%State{} = local, {%State{} = remote, remote_map}) do
    merge(local, remote, remote_map)
  end

  defp merge(local, remote, remote_map) do
    {pids, joins} = accumulate_joins(local, remote_map)
    {clouds, delta, leaves} = observe_removes(local, remote, remote_map)
    true = :ets.insert(local.values, joins)
    true = :ets.insert(local.pids, pids)
    known_remote_context = Map.take(remote.context, Map.keys(local.context))
    ctx = Clock.upperbound(local.context, known_remote_context)
    new_state =
      %State{local | clouds: clouds, delta: delta}
      |> put_context(ctx)
      |> compact()

    {new_state, joins, leaves}
  end

  @spec accumulate_joins(t, values) :: joins :: {[pid_lookup], [values]}
  defp accumulate_joins(local, remote_map) do
    %State{context: context, clouds: clouds} = local
    Enum.reduce(remote_map, {[], []}, fn {{replica, _} = tag, {pid, topic, key, meta}}, {pids, adds} ->
      if not match?(%{^replica => _}, context) or in?(context, clouds, tag) do
        {pids, adds}
      else
        {[{pid, topic, key} | pids], [{{topic, pid, key}, meta, tag} | adds]}
      end
    end)
  end

  @spec observe_removes(t, t, map) :: {clouds, delta, leaves :: [value]}
  defp observe_removes(%State{pids: pids, values: values, delta: delta} = local, remote, remote_map) do
    unioned_clouds = union_clouds(local, remote)
    %State{context: remote_context, clouds: remote_clouds} = remote
    init = {unioned_clouds, delta, []}
    local_replica = local.replica
    # fn {_, _, {replica, _}} = result when replica != local_replica -> result end
    ms = [{
      {:_, :_, {:"$1", :_}},
      [{:"/=", :"$1", {:const, local_replica}}],
      [:"$_"]
    }]

    foldl(values, init, ms, fn {{topic, pid, key} = values_key, _, tag} = el, {clouds, delta, leaves} ->
      if not match?(%{^tag => _}, remote_map) and in?(remote_context, remote_clouds, tag) do
        :ets.delete(values, values_key)
        :ets.match_delete(pids, {pid, topic, key})
        {delete_tag(clouds, tag), remove_delta_tag(delta, tag), [el | leaves]}
      else
        {clouds, delta, leaves}
      end
    end)
  end

  defp put_tag(clouds, {name, _clock} = tag) do
    case clouds do
      %{^name => cloud} -> %{clouds | name => MapSet.put(cloud, tag)}
      _ -> Map.put(clouds, name, MapSet.new([tag]))
    end
  end

  defp delete_tag(clouds, {name, _clock} = tag) do
    case clouds do
      %{^name => cloud} -> %{clouds | name => MapSet.delete(cloud, tag)}
      _ -> clouds
    end
  end

  defp union_clouds(%State{mode: :delta} = local, %State{} = remote) do
    Enum.reduce(remote.clouds, local.clouds, fn {name, remote_cloud}, acc ->
      Map.update(acc, name, remote_cloud, &MapSet.union(&1, remote_cloud))
    end)
  end
  defp union_clouds(%State{mode: :normal, context: local_ctx} = local, %State{} = remote) do
    Enum.reduce(remote.clouds, local.clouds, fn {name, remote_cloud}, acc ->
      if Map.has_key?(local_ctx, name) do
        Map.update(acc, name, remote_cloud, &MapSet.union(&1, remote_cloud))
      else
        acc
      end
    end)
  end

  def merge_deltas(%State{mode: :delta} = local, %State{mode: :delta, values: remote_values} = remote) do
    %{values: local_values, range: {local_start, local_end}, context: local_context, clouds: local_clouds} = local
    %{range: {remote_start, remote_end}, context: remote_context, clouds: remote_clouds} = remote

    if (Clock.dominates_or_equal?(remote_end, local_start) and
        Clock.dominates_or_equal?(local_end, remote_start)) or
       (Clock.dominates_or_equal?(local_end, remote_start) and
        Clock.dominates_or_equal?(remote_end, local_start)) do
      new_start = Clock.lowerbound(local_start, remote_start)
      new_end = Clock.upperbound(local_end, remote_end)
      clouds = union_clouds(local, remote)

      filtered_locals = for {tag, value} <- local_values,
                        match?(%{^tag => _}, remote_values) or not in?(remote_context, remote_clouds, tag),
                        do: {tag, value}

      merged_vals = for {tag, value} <- remote_values,
                    not match?(%{^tag => _}, local_values) and not in?(local_context, local_clouds, tag),
                    into: filtered_locals,
                    do: {tag, value}

      {:ok, %State{local | clouds: clouds, values: Map.new(merged_vals), range: {new_start, new_end}}}
    else
      {:error, :not_contiguous}
    end
  end

  @doc """
  Marks a replica as up in the set and returns rejoined users.
  """
  @spec replica_up(t, name) :: {t, joins :: [values], leaves :: []}
  def replica_up(%State{replicas: replicas, context: ctx} = state, replica) do
    {%State{state |
            context: Map.put_new(ctx, replica, 0),
            replicas: Map.put(replicas, replica, :up)}, replica_users(state, replica), []}
  end

  @doc """
  Marks a replica as down in the set and returns left users.
  """
  @spec replica_down(t, name) :: {t, joins:: [], leaves :: [values]}
  def replica_down(%State{replicas: replicas} = state, replica) do
    {%State{state | replicas: Map.put(replicas, replica, :down)}, [], replica_users(state, replica)}
  end

  @doc """
  Removes all elements for replicas that are permanently gone.
  """
  @spec remove_down_replicas(t, name) :: t
  def remove_down_replicas(%State{mode: :normal, context: ctx, values: values, pids: pids} = state, replica) do
    new_ctx = Map.delete(ctx, replica)
    # fn {key, _, {^replica, _}} -> key end
    ms = [{{:"$1", :_, {replica, :_}}, [], [:"$1"]}]


    foldl(values, nil, ms, fn {topic, pid, key} = values_key, _ ->
      :ets.delete(values, values_key)
      :ets.match_delete(pids, {pid, topic, key})
      nil
    end)
    new_clouds = Map.delete(state.clouds, replica)
    new_delta = remove_down_replicas(state.delta, replica)

    %State{state | context: new_ctx, clouds: new_clouds, delta: new_delta}
  end
  def remove_down_replicas(%State{mode: :delta, range: range} = delta, replica) do
    {start_ctx, end_ctx} = range
    new_start = Map.delete(start_ctx, replica)
    new_end = Map.delete(end_ctx, replica)
    new_clouds = Map.delete(delta.clouds, replica)
    new_vals = Enum.reduce(delta.values, delta.values, fn
      {{^replica, _clock} = tag, {_pid, _topic, _key, _meta}}, vals ->
        Map.delete(vals, tag)
      {{_replica, _clock} = _tag, {_pid, _topic, _key, _meta}}, vals ->
        vals
    end)

    %State{delta | range: {new_start, new_end}, clouds: new_clouds, values: new_vals}
  end

  @doc """
  Returns the dize of the delta.
  """
  @spec delta_size(delta) :: pos_integer
  def delta_size(%State{mode: :delta, clouds: clouds, values: values}) do
    Enum.reduce(clouds, map_size(values), fn {_name, cloud}, sum ->
      sum + MapSet.size(cloud)
    end)
  end

  @spec add(t, pid, topic, key, meta) :: t
  defp add(%State{} = state, pid, topic, key, meta) do
    state
    |> bump_clock()
    |> do_add(pid, topic, key, meta)
  end
  defp do_add(%State{delta: delta} = state, pid, topic, key, meta) do
    tag = tag(state)
    true = :ets.insert(state.values, {{topic, pid, key}, meta, tag})
    true = :ets.insert(state.pids, {pid, topic, key})
    new_delta = %State{delta | values: Map.put(delta.values, tag, {pid, topic, key, meta})}
    %State{state | delta: new_delta}
  end

  @spec remove(t, pid, topic, key) :: t
  defp remove(%State{pids: pids, values: values} = state, pid, topic, key) do
    [{{^topic, ^pid, ^key}, _meta, tag}] = :ets.lookup(values, {topic, pid, key})
    1 = :ets.select_delete(values, [{{{topic, pid, key}, :_, :_}, [], [true]}])
    1 = :ets.select_delete(pids, [{{pid, topic, key}, [], [true]}])
    pruned_clouds = delete_tag(state.clouds, tag)
    new_delta = remove_delta_tag(state.delta, tag)

    bump_clock(%State{state | clouds: pruned_clouds, delta: new_delta})
  end

  @spec remove_delta_tag(delta, tag) :: delta
  defp remove_delta_tag(%{mode: :delta, values: values, clouds: clouds} = delta, tag) do
    %{delta | clouds: put_tag(clouds, tag), values: Map.delete(values, tag)}
  end

  @doc """
  Compacts a sets causal history.

  Called as needed and after merges.
  """
  @spec compact(t) :: t
  def compact(%State{context: ctx, clouds: clouds} = state) do
    {new_ctx, new_clouds} =
      Enum.reduce(clouds, {ctx, clouds}, fn {name, cloud}, {ctx_acc, clouds_acc} ->
        {new_ctx, new_cloud} = do_compact(ctx_acc, Enum.sort(MapSet.to_list(cloud)))
        {new_ctx, Map.put(clouds_acc, name, MapSet.new(new_cloud))}
      end)

    put_context(%State{state | clouds: new_clouds}, new_ctx)
  end
  @spec do_compact(context, sorted_cloud_list :: list) :: {context, cloud}
  defp do_compact(ctx, cloud) do
    Enum.reduce(cloud, {ctx, []}, fn {replica, clock} = tag, {ctx_acc, cloud_acc} ->
      case ctx_acc do
        %{^replica => ctx_clock} when ctx_clock + 1 == clock ->
          {%{ctx_acc | replica => clock}, cloud_acc}
        %{^replica => ctx_clock} when ctx_clock >= clock ->
          {ctx_acc, cloud_acc}
        _ when clock == 1 ->
          {Map.put(ctx_acc, replica, clock), cloud_acc}
        _ ->
          {ctx_acc, [tag | cloud_acc]}
      end
    end)
  end

  @compile {:inline, in?: 3, in_ctx?: 3, in_clouds?: 3}

  defp in?(context, clouds, {replica, clock} = tag) do
    in_ctx?(context, replica, clock) or in_clouds?(clouds, replica, tag)
  end
  defp in_ctx?(ctx, replica, clock) do
    case ctx do
      %{^replica => replica_clock} -> replica_clock >= clock
      _ -> false
    end
  end
  defp in_clouds?(clouds, replica, tag) do
    case clouds do
      %{^replica => cloud} -> MapSet.member?(cloud, tag)
      _ -> false
    end
  end

  @spec tag(t) :: tag
  defp tag(%State{replica: rep} = state), do: {rep, clock(state)}

  @spec clock(t) :: clock
  defp clock(%State{replica: rep, context: ctx}), do: Map.get(ctx, rep, 0)

  @spec bump_clock(t) :: t
  defp bump_clock(%State{mode: :normal, replica: rep, clouds: clouds, context: ctx, delta: delta} = state) do
    new_clock = clock(state) + 1
    new_ctx = Map.put(ctx, rep, new_clock)

    %State{state |
           clouds: put_tag(clouds, {rep, new_clock}),
           delta: %State{delta | clouds: put_tag(delta.clouds, {rep, new_clock})}}
    |> put_context(new_ctx)
  end
  defp put_context(%State{delta: delta, replica: rep} = state, new_ctx) do
    {start_clock, end_clock} = delta.range
    new_end = Map.put(end_clock, rep, Map.get(new_ctx, rep, 0))
    %State{state |
           context: new_ctx,
           delta: %State{delta | range: {start_clock, new_end}}}
  end

  @spec down_replicas(t) :: [name]
  defp down_replicas(%State{replicas: replicas})  do
    for {replica, :down} <- replicas, do: replica
  end

  @spec replica_users(t, name) :: [value]
  defp replica_users(%State{values: values}, replica) do
    :ets.match_object(values, {:_, :_, {replica, :_}})
  end

  @fold_batch_size 1000

  defp foldl(table, initial, ms, func) do
    foldl(:ets.select(table, ms, @fold_batch_size), initial, func)
  end

  defp foldl(:"$end_of_table", acc, _func), do: acc
  defp foldl({objects, cont}, acc, func) do
    foldl(:ets.select(cont), Enum.reduce(objects, acc, func), func)
  end
end
