defmodule Phoenix.Tracker.State do
  alias Phoenix.Tracker.State.Delta
  alias __MODULE__

  require Delta

  @type actor :: term
  @type clock :: pos_integer
  @type dot :: {actor, clock}
  @type ctx_clock :: %{ actor => clock }
  @type conn :: term
  @type key :: term
  @type topic :: term
  @type metadata :: %{}
  @type value :: {conn, topic, key, metadata}
  @type opts :: Keyword.t

  @type joins :: [value]
  @type parts :: [value]
  @type noderef :: {node, term}
  @type node_status :: :up | :down
  @type entry :: {noderef, value}

  @opaque t :: %State{
    actor: nil,
    dots: %{dot => value},
    ctx: ctx_clock,
    cloud: [dot],
    delta: Delta.t,
    delta1: Delta.t,
    delta2: Delta.t,
    servers: %{ noderef => node_status }
  }

  defstruct actor: nil,
            dots: %{}, # A map of dots (version-vector pairs) to values
            ctx: %{},  # Current counter values for actors used in the dots
            cloud: [],  # A set of dots that we've seen but haven't been merged.
            delta: %Delta{},
            delta1: %Delta{}, # Gen1 delta
            delta2: %Delta{}, # Gen2 delta
            servers: %{}

  @spec new(noderef) :: t
  def new({_,_}=node) do
    servers = Enum.into([{node, :up}], %{})
    %State{actor: node, actor: node, servers: servers}
  end

  @spec actor(t) :: actor
  def actor(%State{actor: actor}), do: actor

  @spec clock(t) :: {actor, ctx_clock}
  def clock(%State{actor: actor, ctx: ctx_clock}), do: {actor, ctx_clock}

  @spec delta(t) :: Delta.t
  def delta(%State{delta: d}), do: d

  @spec delta_reset(t) :: {State.t, Delta.t}
  def delta_reset(set), do: {reset_delta(set), delta(set)}

  @spec reset_delta(t) :: t
  def reset_delta(%State{actor: actor, ctx: ctx}=set) do
    %State{set| delta: %State.Delta{start_clock: ctx, end_clock: ctx}}
  end

  @spec remove_down_nodes(t, noderef) :: t
  def remove_down_nodes(%{ctx: ctx, dots: dots} = set, noderef) do
    new_ctx = Enum.reject(ctx, &match?({^noderef, _}, &1)) |> Enum.into(%{})
    new_dots = for {{dot, _} = nodespec, v} <- dots, dot != noderef, into: %{} do
      {nodespec, v}
    end

    %{set | ctx: new_ctx, dots: new_dots}
  end

  @spec node_down(t, noderef) :: {t, joins, parts}
  def node_down(%State{servers: servers}=set, {_,_}=node) do
    new_set = %State{set|servers: Map.put(servers, node, :down)}
    {new_set, [], node_users(new_set, node)}
  end

  @spec node_up(t, noderef) :: {t, joins, parts}
  def node_up(%State{servers: servers}=set, {_,_}=node) do
    new_set = %State{set|servers: Map.put(servers, node, :up)}
    {new_set, node_users(new_set, node), []}
  end

  @spec join(t, conn, topic, key) :: t
  @spec join(t, conn, topic, key, metadata) :: t
  def join(%State{}=set, conn, topic, key, metadata \\ %{}) do
    add(set, {conn, topic, key, metadata})
  end

  @spec part(t, conn) :: t
  def part(%State{}=set, conn) do
    remove(set, &match?({^conn,_,_,_}, &1))
  end

  @spec part(t, conn, topic, key) :: t
  def part(%State{}=set, conn, topic, key) do
    remove(set, &match?({^conn,^topic,^key,_}, &1))
  end

  @spec get_by_conn(t, conn) :: [entry]
  def get_by_conn(%State{dots: dots, servers: servers}, conn) do
    for {{nodespec, _}, {^conn, _topic, _key, _metadata}} = entry <- dots, Map.get(servers, nodespec, :up)==:up do
      entry
    end
  end

  @spec get_by_conn(t, conn, topic, key) :: entry | nil
  def get_by_conn(%State{dots: dots, servers: servers}, conn, topic, key) do
    results = for {{nodespec, _}, {^conn, ^topic, ^key, _metadata}} = entry <- dots, Map.get(servers, nodespec, :up)==:up do
      entry
    end

    case results do
      [result] -> result
      [] -> nil
    end
  end

  @spec get_by_key(t, key) :: [{conn, topic, metadata}]
  def get_by_key(%State{dots: dots, servers: servers}, key) do
    for {{nodespec, _}, {conn, topic, ^key, metadata}} <- dots, Map.get(servers, nodespec, :up)==:up, do: {conn, topic, metadata}
  end

  @spec get_by_topic(t, topic) :: [{conn, key, metadata}]
  def get_by_topic(%State{dots: dots, servers: servers}, topic) do
    for {{nodespec, _}, {conn, ^topic, key, metadata}} <- dots, Map.get(servers, nodespec, :up)==:up, do: {conn, key, metadata}
  end

  @spec online_users(t) :: [value]
  def online_users(%{dots: dots, servers: servers}) do
    for {{node,_}, {_, _, user, _}} <- dots, Map.get(servers, node, :up) == :up do
      user
    end |> Enum.uniq
  end

  defp node_users(%{dots: dots}, node) do
    for {{n,_}, user} <- dots, n===node do
      {node, user}
    end |> Enum.uniq
  end

  @spec offline_users(t) :: [value]
  def offline_users(%{dots: dots, servers: servers}) do
    for {{node,_}, {_, _, user, _}} <- dots, Map.get(servers, node, :up) == :down do
      user
    end |> Enum.uniq
  end

  @spec down_servers(t) :: [noderef]
  def down_servers(%State{servers: servers}) do
    for {node, :down} <- servers, do: node
  end

  @doc """
  Compact the dots.

  This merges any newly-contiguously-joined deltas. This is usually called
  automatically as needed.
  """
  @spec compact(t) :: t
  def compact(dots), do: do_compact(dots)

  @doc """
  Joins any 2 dots together.

  Automatically compacts any contiguous dots.
  """
  @spec merge(t, t | Delta.t | [Delta.t]) :: {t, joins, parts}
  def merge(dots1, dots2), do: do_merge(dots1, dots2)

  # @doc """
  # Adds and associates a value with a new dot for an actor.
  # """
  # @spec add(t, value) :: t
  defp add(%State{}=set, {_,_,_,_}=value) do
    %{actor: actor, dots: dots, ctx: ctx, delta: delta} = set
    clock = Dict.get(ctx, actor, 0) + 1 # What's the value of our clock?
    %{cloud: cloud, dots: delta_dots} = delta

    new_ctx = Dict.put(ctx, actor, clock) # Add the actor/clock to the context
    new_dots = Dict.put(dots, {actor, clock}, value) # Add the value to the dot values

    new_cloud = [{actor, clock}|cloud]
    new_delta_dots = Dict.put(delta_dots, {actor,clock}, value)

    new_delta = %{delta| cloud: new_cloud, dots: new_delta_dots}
    %{set| ctx: new_ctx, delta: new_delta, dots: new_dots}
  end

  # @doc """
  # Removes a value from the set
  # """
  # @spec remove(t | {t, t}, value | (value -> boolean)) :: t
  defp remove(%State{}=set, pred) when is_function(pred) do
    %{actor: actor, ctx: ctx, dots: dots, delta: delta} = set
    %{cloud: cloud, dots: delta_dots} = delta

    clock = Dict.get(ctx, actor, 0) + 1
    new_ctx = Dict.put(ctx, actor, clock)
    new_dots = for {dot, v} <- dots, !pred.(v), into: %{}, do: {dot, v}

    new_cloud = [{actor, clock}|cloud] ++ Enum.filter_map(dots, fn {_, v} -> pred.(v) end, fn {dot,_} -> dot end)
    new_delta_dots = for {dot, v} <- delta_dots, !pred.(v), into: %{}, do: {dot, v}
    new_delta = %{delta| cloud: new_cloud, dots: new_delta_dots}

    %{set| ctx: new_ctx, dots: new_dots, delta: new_delta}
  end

  defp do_compact(%{ctx: ctx, cloud: c}=dots) do
    {new_ctx, new_cloud} = compact_reduce(Enum.sort(c), ctx, [])
    %{dots|ctx: new_ctx, cloud: new_cloud}
  end

  defp compact_reduce([], ctx, cloud_acc) do
    {ctx, Enum.reverse(cloud_acc)}
  end
  defp compact_reduce([{actor, clock}=dot|cloud], ctx, cloud_acc) do
    case {ctx[actor], clock} do
      {nil, 1} ->
        # We can merge nil with 1 in the cloud
        compact_reduce(cloud, Dict.put(ctx, actor, clock), cloud_acc)
      {nil, _} ->
        # Can't do anything with this
        compact_reduce(cloud, ctx, [dot|cloud_acc])
      {ctx_clock, _} when ctx_clock + 1 == clock ->
        # Add to context, delete from cloud
        compact_reduce(cloud, Dict.put(ctx, actor, clock), cloud_acc)
      {ctx_clock, _} when ctx_clock >= clock -> # Dominates
        # Delete from cloud by not accumulating.
        compact_reduce(cloud, ctx, cloud_acc)
      {_, _} ->
        # Can't do anything with this.
        compact_reduce(cloud, ctx, [dot|cloud_acc])
    end
  end

  defp dotin(%State.Delta{cloud: cloud}, {_,_}=dot) do
    Enum.any?(cloud, &(&1==dot))
  end
  defp dotin(%State{ctx: ctx, cloud: cloud}, {actor, clock}=dot) do
    # If this exists in the dot, and is greater than the value *or* is in the cloud
    (ctx[actor]||0) >= clock or Enum.any?(cloud, &(&1==dot))
  end

  defp do_merge(%{dots: d1, ctx: ctx1, cloud: c1}=set1, %{dots: d2, cloud: c2}=set2) do
    # new_dots = do_merge_dots(Enum.sort(d1), Enum.sort(d2), {dots1, dots2}, [])
    {new_dots,j,p} = Enum.sort(extract_dots(d1, set2) ++ extract_dots(d2, set1))
               |> merge_dots(set1, {%{},[],[]})
    new_ctx = Dict.merge(ctx1, Map.get(set2, :ctx, %{}), fn (_, a, b) -> max(a, b) end)
    new_cloud = Enum.uniq(c1 ++ c2)
    {compact(%{set1|dots: new_dots, ctx: new_ctx, cloud: new_cloud}),j,p}
  end

  # Pair each dot with the set opposite it for comparison
  defp extract_dots(dots, set) do
    for pair <- dots, do: {pair, set}
  end

  defp merge_dots([], _, acc), do: acc

  defp merge_dots([{{dot,value}=pair,_}, {pair,_} |rest], set1, {acc,j,p}) do
    merge_dots(rest, set1, {Map.put(acc, dot, value),j,p})
  end

  # Our dot's values aren't the same. This is an invariant and shouldn't happen. ever.
  defp merge_dots([{{dot,_},_}, {{dot,_},_}|_], _, _acc) do
    raise Phoenix.Tracker.State.InvariantError, "2 dot-pairs with the same dot but different values"
  end

  # Our dots aren't the same.
  # TODO: FILTER PARTS AND JOINS FOR DOWN NODES!
  defp merge_dots([{{{actor, _}=dot,value}, oppset}|rest], %{actor: me, delta: delta}=set1, {acc,j,p}) do
    # Check to see if this dot is in the opposite CRDT
    %{cloud: cloud, dots: delta_dots} = delta
    {new_acc, new_delta} = if dotin(oppset, dot) do
      # It *was* here, we drop it (observed-delete dot-pair)
      new_p = if actor != me, do: [{actor, value}|p], else: p
      {{acc,j,new_p}, %{delta| cloud: [dot|cloud]}}
    else
      # If it wasn't here, we keep it (concurrent update)
      new_j = if actor != me, do: [{actor, value}|j], else: j
      acc = Map.put(acc, dot, value)
      new_delta_dots = Map.put(delta_dots, dot, value)
      {{acc,new_j,p}, %{delta| cloud: [dot|cloud], dots: new_delta_dots}}
    end
    merge_dots(rest, %{set1| delta: new_delta}, new_acc)
  end

end
