defmodule SalixAgent.TaskRouting.Learner do
  @moduledoc """
  Per-route evidence and seeded Thompson sampling over model arms.

  A route is one row of a routing table: a key and a description that the
  decision model chose for a Task. The learner assumes nothing about what a
  key means, so routes never share evidence. An arm is one Model Choice with a
  reasoning effort. Each route keeps its own evidence for each arm.

  The value of an arm is its expected completion rate divided by its expected
  USD cost for one Task, so the best arm has the lowest cost per completed
  Task. At most one Task in ten explores: it samples a completion rate for
  each arm from its Beta posterior. Every other Task takes the arm with the
  best mean value among the route's configured arm and the arms with enough
  evidence. A seed decides both draws, so the same Task always gets the same
  arm.
  """

  @window 1024
  @explore_share 0.1
  @minimum_evidence 5
  @update_weight 0.2
  # Token use assumed for an arm when the route has no measurement. It only
  # orders arms by price until Tasks report their usage.
  @nominal %{
    "input_tokens" => 100_000,
    "output_tokens" => 10_000,
    "cache_read_input_tokens" => 0,
    "cache_write_input_tokens" => 0
  }
  @token_keys ~w(cache_read_input_tokens cache_write_input_tokens input_tokens output_tokens)
  @price_keys ~w(cache_read cache_write input output)

  def feedback(body) when is_map(body) do
    outcome = body["outcome"]
    quality = body["quality"]
    resources = body["resources"]

    if Map.keys(body) -- ~w(outcome quality resources) == [] and
         outcome in ~w(completed task_failure timeout infrastructure unattributed) and
         (is_nil(quality) or (outcome == "completed" and in_range?(quality, 0, 1))) and
         (is_nil(resources) or valid_resources?(resources)) do
      {:ok, %{"outcome" => outcome, "quality" => quality, "resources" => resources}}
    else
      invalid("invalid Task routing feedback")
    end
  end

  def feedback(_), do: invalid("invalid Task routing feedback")

  @doc "Token counts, with optional active `seconds`. Total input includes both cache categories."
  def valid_resources?(resources) when is_map(resources) do
    (Map.keys(resources) -- ["seconds"]) |> Enum.sort() == @token_keys and
      Enum.all?(Map.values(resources), &in_range?(&1, 0, 1.0e12)) and
      resources["cache_read_input_tokens"] + resources["cache_write_input_tokens"] <=
        resources["input_tokens"]
  end

  def valid_resources?(_), do: false

  @doc """
  A route's evidence generation: its key and description. A changed
  description starts new evidence. Other rows, the arms and the routing switch
  do not. Map ordering cannot change the identity after a JSON round trip.
  """
  def generation(key, description) do
    {key, description}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "A stable identity for a Model Choice, used to keep an arm's evidence."
  def arm_key(choice) when is_map(choice) do
    choice
    |> Map.take(~w(kind model tier reasoning_effort allow_paid profile_id))
    |> Map.put_new("kind", "catalog")
    |> Map.reject(fn {key, value} ->
      is_nil(value) or (key == "allow_paid" and value == false)
    end)
    |> Enum.sort()
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  def empty, do: %{"revision" => 0, "observations" => []}

  # Deduplication lives in the durable receipt table, outside this finite window.
  def update(state, observation) do
    %{
      "revision" => state["revision"] + 1,
      "observations" => Enum.take(state["observations"] ++ [observation], -@window)
    }
  end

  @doc """
  Chooses an arm for one Task of a route. `arms` are maps with `key`,
  `choice` and `price` (USD per million tokens, or nil when unknown). `initial`
  is the arm the route is configured with; it is used when no other arm can be
  priced. `seed` is a binary that identifies the Task.
  """
  def choose(arms, initial, state, seed) when is_binary(seed) do
    arms = with_initial(arms, initial)
    stats = stats(arms, state)
    reference = Enum.find(stats, &(&1.key == initial["key"]))
    priced = Enum.filter(stats, &is_number(&1.usd))
    {draw, rng} = :rand.uniform_s(rng(seed))

    {selected, reason} =
      cond do
        not is_number(reference.usd) ->
          {reference, "initial"}

        draw < @explore_share ->
          {sampled(priced, rng), "explore"}

        true ->
          best = best(priced, reference)
          {best, if(best.key == reference.key, do: "initial", else: "value")}
      end

    Map.merge(describe(selected), %{"reason" => reason, "choice" => selected.choice})
  end

  # The best mean value among the configured arm and the arms with enough
  # evidence. A tie keeps the configured arm.
  defp best(priced, reference) do
    if is_number(reference.usd) do
      priced
      |> Enum.filter(&(&1.key == reference.key or &1.tasks >= @minimum_evidence))
      |> Enum.max_by(&{&1.mean / max(&1.usd, 1.0e-12), &1.key == reference.key})
    else
      reference
    end
  end

  @doc """
  The configured arm and each arm with evidence. The first is the arm a Task
  takes when it does not explore.
  """
  def summary(arms, initial, state) do
    stats = arms |> with_initial(initial) |> stats(state)
    reference = Enum.find(stats, &(&1.key == initial["key"]))
    current = best(Enum.filter(stats, &is_number(&1.usd)), reference)

    [current | Enum.filter(stats, &(&1.tasks > 0 and &1.key != current.key))]
    |> Enum.map(&Map.put(describe(&1), "choice", &1.choice))
  end

  defp with_initial(arms, initial) do
    if Enum.any?(arms, &(&1["key"] == initial["key"])), do: arms, else: [initial | arms]
  end

  defp stats(arms, state) do
    by_arm = Enum.group_by(state["observations"], & &1["arm"])
    measured = Enum.flat_map(state["observations"], &measured/1)
    pooled = if measured == [], do: @nominal, else: average(measured)

    Enum.map(arms, fn arm ->
      known = Enum.filter(Map.get(by_arm, arm["key"], []), &known?/1)
      successes = Enum.count(known, &(&1["outcome"] == "completed"))
      n = length(known)

      resources =
        known
        |> Enum.flat_map(&measured/1)
        |> Enum.reduce(nil, fn values, previous ->
          if previous,
            do: Map.new(@token_keys, &{&1, ema(previous[&1], values[&1])}),
            else: values
        end)

      %{
        key: arm["key"],
        choice: arm["choice"],
        tasks: n,
        successes: successes,
        failures: n - successes,
        mean: (successes + 1) / (n + 2),
        usd: price_of(resources || pooled, arm["price"])
      }
    end)
  end

  defp measured(%{"outcome" => outcome, "resources" => %{} = resources})
       when outcome in ~w(completed task_failure),
       do: [Map.take(resources, @token_keys)]

  defp measured(_), do: []

  defp average(values) do
    count = length(values)
    Map.new(@token_keys, fn key -> {key, Enum.sum(Enum.map(values, & &1[key])) / count} end)
  end

  defp valid_price?(price) when is_map(price) do
    Enum.sort(Map.keys(price)) == @price_keys and
      Enum.all?(Map.values(price), &in_range?(&1, 0, 100_000))
  end

  defp valid_price?(_), do: false

  defp price_of(resources, price) do
    if valid_price?(price) and Enum.any?(Map.values(price), &(&1 > 0)),
      do: cost(resources, price)
  end

  # Thompson sampling: the arm whose sampled completion rate buys the most
  # completions per dollar.
  defp sampled(priced, rng) do
    {scored, _} =
      Enum.map_reduce(priced, rng, fn arm, rng ->
        {rate, rng} = beta(arm.successes + 1, arm.failures + 1, rng)
        {{rate / max(arm.usd, 1.0e-12), arm}, rng}
      end)

    scored |> Enum.max_by(&elem(&1, 0)) |> elem(1)
  end

  defp describe(arm),
    do: %{
      "arm" => arm.key,
      "tasks" => arm.tasks,
      "completion_probability" => arm.mean,
      "expected_usd" => arm.usd
    }

  # Beta(a, b) as X / (X + Y) of two Gamma draws. Both shapes are at least 1.
  def beta(a, b, rng) do
    {x, rng} = gamma(a, rng)
    {y, rng} = gamma(b, rng)
    {x / (x + y), rng}
  end

  # Marsaglia and Tsang, for shape >= 1.
  defp gamma(shape, rng) do
    d = shape - 1 / 3
    c = 1 / :math.sqrt(9 * d)
    gamma(d, c, rng)
  end

  defp gamma(d, c, rng) do
    {x, rng} = :rand.normal_s(rng)
    v = :math.pow(1 + c * x, 3)
    {u, rng} = :rand.uniform_s(rng)

    if v > 0 and :math.log(u) < 0.5 * x * x + d - d * v + d * :math.log(v),
      do: {d * v, rng},
      else: gamma(d, c, rng)
  end

  @doc "A random state determined by `seed`."
  def rng(seed) do
    <<a::64, b::64, c::64, _::binary>> = :crypto.hash(:sha256, seed)
    :rand.seed_s(:exsss, {a, b, c})
  end

  def cost(resources, price) do
    read = resources["cache_read_input_tokens"]
    write = resources["cache_write_input_tokens"]

    (max(resources["input_tokens"] - read - write, 0) * price["input"] +
       read * price["cache_read"] + write * price["cache_write"] +
       resources["output_tokens"] * price["output"]) / 1_000_000
  end

  defp known?(observation), do: observation["outcome"] in ~w(completed task_failure timeout)
  defp ema(previous, value), do: (1 - @update_weight) * previous + @update_weight * value
  defp in_range?(value, low, high), do: is_number(value) and value >= low and value <= high
  defp invalid(message), do: {:error, {:bad_request, message}}
end
