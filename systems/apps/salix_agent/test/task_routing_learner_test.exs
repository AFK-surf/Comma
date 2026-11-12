defmodule SalixAgent.TaskRoutingLearnerTest do
  use ExUnit.Case, async: true
  alias SalixAgent.TaskRouting.Learner
  alias SalixAgent.RoutingLearningFixture, as: Fixture

  @strong %{"input" => 10, "output" => 30, "cache_read" => 1, "cache_write" => 12}
  @cheap %{"input" => 1, "output" => 3, "cache_read" => 0.1, "cache_write" => 1.2}

  defp arm(model, price) do
    choice = %{"kind" => "catalog", "model" => model, "reasoning_effort" => "high"}
    %{"key" => Learner.arm_key(choice), "choice" => choice, "price" => price}
  end

  defp record(state, arm, outcome, times) do
    Enum.reduce(1..times, state, fn _, s ->
      Learner.update(s, Fixture.observation(arm["key"], outcome))
    end)
  end

  defp choices(arms, initial, state) do
    for seed <- 1..1000, do: Learner.choose(arms, initial, state, "task-#{seed}")
  end

  test "without evidence a route keeps its model and explores about one Task in ten" do
    strong = arm("gpt-6-sol", @strong)
    arms = [strong, arm("gpt-6-luna", @cheap)]
    results = choices(arms, strong, Learner.empty())

    explored = Enum.count(results, &(&1["reason"] == "explore"))
    assert explored in 70..130
    assert Enum.all?(results, &(&1["reason"] == "explore" or &1["arm"] == strong["key"]))

    assert Learner.choose(arms, strong, Learner.empty(), "task-7") ==
             Learner.choose(arms, strong, Learner.empty(), "task-7")
  end

  test "an arm with enough completions at a lower cost per completion takes over" do
    strong = arm("gpt-6-sol", @strong)
    cheap = arm("gpt-6-luna", @cheap)
    arms = [strong, cheap]

    state = Learner.empty() |> record(strong, "completed", 5) |> record(cheap, "completed", 4)
    assert Learner.choose(arms, strong, state, "task-1")["reason"] == "initial"

    state = record(state, cheap, "completed", 1)
    taken = choices(arms, strong, state) |> Enum.reject(&(&1["reason"] == "explore"))
    assert Enum.all?(taken, &(&1["arm"] == cheap["key"] and &1["reason"] == "value"))
    assert [%{"arm" => current} | _] = Learner.summary(arms, strong, state)
    assert current == cheap["key"]

    failing = record(state, cheap, "task_failure", 200)
    taken = choices(arms, strong, failing) |> Enum.reject(&(&1["reason"] == "explore"))
    assert Enum.all?(taken, &(&1["arm"] == strong["key"]))
  end

  test "catalog prices let a Terra route explore a cheaper model" do
    {:ok, terra} = SalixAgent.Models.get("gpt-6.1-terra")
    {:ok, luna} = SalixAgent.Models.get("gpt-6-luna")
    initial = arm(terra["id"], terra["price"])
    cheaper = arm(luna["id"], luna["price"])

    assert Enum.any?(
             choices([initial, cheaper], initial, Learner.empty()),
             &(&1["arm"] == cheaper["key"] and &1["reason"] == "explore")
           )
  end

  test "infrastructure and unattributed outcomes are not evidence" do
    strong = arm("gpt-6-sol", @strong)
    cheap = arm("gpt-6-luna", @cheap)

    state =
      Learner.empty() |> record(cheap, "infrastructure", 10) |> record(cheap, "unattributed", 10)

    taken = choices([strong, cheap], strong, state) |> Enum.reject(&(&1["reason"] == "explore"))
    assert Enum.all?(taken, &(&1["arm"] == strong["key"]))
  end

  test "arms without a price are never sampled, and an unpriced route keeps its model" do
    strong = arm("gpt-6-sol", @strong)
    unpriced = arm("local-model", nil)
    state = record(Learner.empty(), unpriced, "completed", 50)

    assert Enum.all?(choices([strong, unpriced], strong, state), &(&1["arm"] == strong["key"]))

    assert Enum.all?(
             choices([strong, unpriced], unpriced, Learner.empty()),
             &(&1["arm"] == unpriced["key"] and &1["reason"] == "initial")
           )
  end

  test "evidence keeps a bounded window and a generation names only the route" do
    strong = arm("gpt-6-sol", @strong)
    state = record(Learner.empty(), strong, "completed", 1030)
    assert state["revision"] == 1030
    assert length(state["observations"]) == 1024

    assert Learner.generation("quick", "Small edits") ==
             Learner.generation("quick", "Small edits")

    refute Learner.generation("quick", "Small edits") ==
             Learner.generation("quick", "Large edits")

    assert Learner.arm_key(%{"model" => "m", "reasoning_effort" => nil, "allow_paid" => false}) ==
             Learner.arm_key(%{"kind" => "catalog", "model" => "m"})
  end

  test "Beta draws stay within the unit interval and follow the evidence" do
    rng = Learner.rng("beta")

    {draws, _} =
      Enum.map_reduce(1..2000, rng, fn _, rng -> Learner.beta(81, 21, rng) end)

    assert Enum.all?(draws, &(&1 > 0 and &1 < 1))
    assert_in_delta Enum.sum(draws) / length(draws), 0.794, 0.01
  end

  test "impossible feedback fails at the input boundary" do
    assert {:error, _} = Learner.feedback(%{"outcome" => "timeout", "quality" => 1})

    assert {:error, _} =
             Learner.feedback(%{
               "outcome" => "completed",
               "resources" => Map.put(Fixture.resources(), "input_tokens", 1)
             })

    assert {:ok, _} =
             Learner.feedback(%{
               "outcome" => "completed",
               "resources" => Map.delete(Fixture.resources(), "seconds")
             })
  end
end
