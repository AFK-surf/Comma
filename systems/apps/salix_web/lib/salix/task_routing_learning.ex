defmodule Salix.TaskRoutingLearning do
  @moduledoc """
  Salix-owned learning for Group and platform model routing.

  A route table learns when its `learning` switch is on. Each route keeps its
  own evidence (`SalixAgent.TaskRouting.Learner`). A Group route table's
  evidence is the Group's, and its arms are every Model Choice and reasoning
  effort the route editor offers the Group now. The platform route table
  (`SalixAgent.PlatformModels.routing/0`) keeps one evidence store for every
  Group it routes (scope `"platform"`), and its arms are the models the
  platform's API keys serve (`SalixWeb.Dashboard.RoutingModels.platform_models/0`).
  The two never read or write each other's evidence: a Task's selection
  metadata names the scope that routed it (`routing_scope`).

  Evidence comes from the Task itself: a review accepted by a person counts
  as a completion, and a failed Task as a failure, with the Worker Session's
  token use. An evaluator can also grade a Group-routed Task through the
  feedback API; platform evidence takes Task results only, so no tenant can
  steer the platform's table. Each Task gives one sample.
  """
  require Logger
  alias SalixAgent.PlatformModels
  alias SalixAgent.TaskRouting.Learner
  alias SalixStore.TaskRoutingLearning, as: Store
  alias Salix.Control.Groups
  alias SalixWeb.Dashboard.{RoutingForm, RoutingModels}

  @tokens ~w(input_tokens output_tokens cache_read_input_tokens cache_write_input_tokens)
  @platform "platform"

  def enabled?(%{"mode" => "routes", "learning" => true}), do: true
  def enabled?(_), do: false

  @doc """
  The model for a Task after the decision model chose its route. Returns the
  route's configured choice unchanged when learning is off.
  """
  def choose(context, policy, routing, candidate, seed) do
    with true <- enabled?(policy),
         {_key, description, _initial} <- route(policy, routing["tag_key"]) do
      generation = Learner.generation(routing["tag_key"], description)

      with {:ok, state} <- Store.get(scope(context), generation, Learner.empty()),
           {:ok, arms} <- arms(context) do
        result = Learner.choose(arms, arm(candidate), state, seed)

        {:ok, result["choice"],
         %{
           "learning_generation" => generation,
           "learning_revision" => state["revision"],
           "learning_arm" => result["arm"],
           "learning_reason" => result["reason"]
         }}
      end
    else
      _ -> {:ok, candidate, %{}}
    end
  end

  @doc "Each route's evidence: its sample count and arms, best mean value first."
  def get(group_id, tenant_id) do
    with {:ok, group} <- Groups.get(group_id, tenant_id),
         {:ok, policy} <- active_policy(group),
         do: summary(group_id, policy)
  end

  @doc "The platform route table's evidence, as `summary/2` answers it."
  def platform_summary(policy), do: summary(@platform, policy)

  def summary(group_id, policy) do
    routes = routes(policy)

    generations =
      Enum.map(routes, fn {key, description, _} -> Learner.generation(key, description) end)

    with {:ok, states} <- Store.get_many(group_id, generations) do
      rows =
        routes
        |> Enum.zip(generations)
        |> Enum.map(fn {{key, _description, initial}, generation} ->
          state = Map.get(states, generation, Learner.empty())

          arms =
            state["observations"]
            |> Enum.map(& &1["arm"])
            |> Enum.uniq()
            |> Enum.map(&arm(Jason.decode!(&1)))

          %{
            "key" => key,
            "generation" => generation,
            "revision" => state["revision"],
            "arms" => Learner.summary(arms, arm(initial), state)
          }
        end)

      {:ok, %{"routes" => rows}}
    end
  end

  # Explicit grades belong to the tenant that owns this Group. The caller can
  # supply outcomes and measurements, but never the Task's arm or route.
  def feedback(group_id, tenant_id, conversation_id, body) do
    with {:ok, group} <- Groups.get(group_id, tenant_id),
         {:ok, conversation} <-
           SalixIM.Conversations.get_group_conversation_record(group_id, conversation_id),
         :ok <- group_routed(conversation),
         {:ok, policy} <- active_policy(group),
         true <-
           conversation["kind"] == "agent_task" and
             conversation["status"] in ~w(ready_for_review completed failed cancelled),
         {:ok, _worker} <- selected_worker(conversation),
         {:ok, grade} <- Learner.feedback(body) do
      record(group_id, policy, conversation, grade)
    else
      false -> {:error, {:bad_request, "Finish the Task before submitting routing feedback"}}
      error -> error
    end
  end

  @doc """
  Called when a Task's status is published. A review a person accepted is a
  completion and a failed Task is a failure. Other changes teach nothing:
  a cancelled Task or one a person ended by hand without a review says nothing
  about the model. The sample is recorded off the Conversation's process.
  """
  def task_status_changed(%{"kind" => "agent_task"} = conversation) do
    evidence = get_in(conversation, ["metadata", "task_model_selection"]) || %{}

    with outcome when is_binary(outcome) <- outcome(conversation),
         true <- is_binary(evidence["learning_generation"]),
         {:ok, false} <-
           Store.recorded?(
             evidence_scope(conversation, evidence),
             conversation["conversation_id"]
           ) do
      context = SystemsObservability.Context.capture()

      case SystemsRuntime.TaskSupervisor.start_child(__MODULE__.Supervisor, fn ->
             SystemsObservability.Context.run(context, fn -> learn(conversation, outcome) end)
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("Task routing feedback could not start: #{inspect(reason)}")
      end
    end

    :ok
  end

  def task_status_changed(_conversation), do: :ok

  # Where a Task's evidence lives: the platform's, or its Group's.
  defp scope(%{"routing_scope" => @platform}), do: @platform
  defp scope(%{"group_id" => group_id}), do: group_id

  defp evidence_scope(conversation, evidence) do
    if evidence["routing_scope"] == @platform,
      do: @platform,
      else: conversation["agent_group_id"]
  end

  defp outcome(%{
         "status" => "completed",
         "manual_status_change" => %{"from_status" => "ready_for_review"}
       }),
       do: "completed"

  defp outcome(%{"status" => "failed"}), do: "task_failure"
  defp outcome(_conversation), do: nil

  defp learn(conversation, outcome) do
    evidence = get_in(conversation, ["metadata", "task_model_selection"]) || %{}
    scope = evidence_scope(conversation, evidence)

    result =
      with {:ok, policy} <- scope_policy(scope),
           {:ok, worker} <- selected_worker(conversation) do
        grade = %{
          "outcome" => outcome,
          "quality" => nil,
          "resources" => usage(worker["agent_id"], worker["payload"]["session_id"])
        }

        record(scope, policy, conversation, grade)
      end

    case result do
      {:ok, _} -> :ok
      {:error, :learning_disabled} -> :ok
      error -> Logger.info("Task routing feedback not recorded: #{inspect(error)}")
    end
  end

  # The Worker Session's provider-reported tokens. Unknown when unreadable.
  defp usage(agent_id, session_id) do
    case SalixAgent.InternalAgentRuntime.get_session_messages(agent_id, session_id,
           history: :full
         ) do
      {:ok, %{"messages" => messages}} ->
        totals =
          Map.new(@tokens, fn key ->
            {key,
             messages
             |> Enum.filter(&(&1["role"] == "assistant"))
             |> Enum.map(&(&1[key] || 0))
             |> Enum.filter(&is_integer/1)
             |> Enum.sum()}
          end)

        cached = totals["cache_read_input_tokens"] + totals["cache_write_input_tokens"]
        resources = Map.update!(totals, "input_tokens", &max(&1, cached))
        if Learner.valid_resources?(resources), do: resources

      _ ->
        nil
    end
  end

  defp record(scope, policy, conversation, grade) do
    evidence = get_in(conversation, ["metadata", "task_model_selection"]) || %{}
    generation = evidence["learning_generation"]

    current =
      case route(policy, evidence["tag_key"]) do
        {key, description, _initial} -> Learner.generation(key, description)
        nil -> nil
      end

    if is_binary(generation) and generation == current and is_binary(evidence["learning_arm"]) do
      observation = Map.put(grade, "arm", evidence["learning_arm"])

      with {:ok, result} <-
             Store.record(
               scope,
               generation,
               conversation["conversation_id"],
               observation,
               Learner.empty(),
               &Learner.update/2
             ) do
        {:ok, %{"revision" => result.state["revision"], "duplicate" => result.duplicate}}
      end
    else
      {:error, {:conflict, "Task does not belong to the route's current learning evidence"}}
    end
  end

  defp active_policy(group), do: learning_policy(group["task_model_selection"])

  defp scope_policy(@platform), do: learning_policy(PlatformModels.routing())

  defp scope_policy(group_id) do
    with {:ok, group} <- Groups.get(group_id), do: active_policy(group)
  end

  defp learning_policy(policy) do
    policy = SalixAgent.TaskRouting.effective(policy)
    if enabled?(policy), do: {:ok, policy}, else: {:error, :learning_disabled}
  end

  defp group_routed(conversation) do
    evidence = get_in(conversation, ["metadata", "task_model_selection"]) || %{}

    if evidence["routing_scope"] == @platform,
      do: {:error, {:conflict, "The platform route table learns from Task results only"}},
      else: :ok
  end

  # Each route as {key, description, configured choice}.
  defp routes(%{"mode" => "routes", "entries" => entries}),
    do: Enum.map(entries, &{&1["key"], &1["description"], &1["model"]})

  defp route(policy, key) when is_binary(key),
    do: Enum.find(routes(policy), &(elem(&1, 0) == key))

  defp route(_policy, _key), do: nil

  # Every model the platform's API keys serve.
  defp arms(%{"routing_scope" => @platform}) do
    with {:ok, models} <- RoutingModels.platform_models() do
      {:ok,
       Enum.flat_map(models, fn option ->
         choice = RoutingForm.choice(option["key"])
         Enum.map(option["routing_efforts"], &arm(Map.put(choice, "reasoning_effort", &1)))
       end)}
    end
  end

  # Every choice the route editor offers the Group now.
  defp arms(context) do
    with {:ok, group} <- Groups.get(context["group_id"]),
         {:ok, page} <- RoutingModels.load(group, context["tenant_id"]) do
      {:ok,
       Enum.flat_map(page["models"], fn option ->
         choice = RoutingForm.choice(option["key"])

         if choice["kind"] == "catalog",
           do:
             Enum.map(
               option["routing_efforts"],
               &arm(Map.put(choice, "reasoning_effort", &1))
             ),
           else: [arm(choice)]
       end)}
    end
  end

  defp arm(choice) do
    choice =
      choice |> Map.put_new("kind", "catalog") |> Map.reject(fn {_, value} -> is_nil(value) end)

    %{"key" => Learner.arm_key(choice), "choice" => choice, "price" => price(choice)}
  end

  defp price(%{"kind" => "catalog", "model" => model}) do
    case SalixAgent.Models.get(model) do
      # The catalog omits cache rates a source does not list; estimate those
      # tokens at the input rate rather than as free.
      {:ok, %{"price" => %{"input" => input, "output" => output} = price}}
      when is_number(input) and is_number(output) ->
        %{
          "input" => input,
          "output" => output,
          "cache_read" => Map.get(price, "cache_read", input),
          "cache_write" => Map.get(price, "cache_write", input)
        }

      _ ->
        nil
    end
  end

  defp price(%{"kind" => "platform", "model" => model}),
    do: price(%{"kind" => "catalog", "model" => model})

  defp price(_choice), do: nil

  defp selected_worker(conversation) do
    evidence = get_in(conversation, ["metadata", "task_model_selection"]) || %{}

    with {:ok, page} <-
           SalixIM.Conversations.list_group_conversation_participants(
             conversation["agent_group_id"],
             conversation["conversation_id"]
           ) do
      case Enum.filter(page["participants"], &(&1["role_label"] == "worker")) do
        [worker] ->
          session_id = get_in(worker, ["payload", "session_id"])

          expected =
            Map.take(evidence["selected_model"] || %{}, ~w(model tier reasoning_effort))

          actual =
            Map.take(
              get_in(worker, ["payload", "session_model"]) || %{},
              ~w(model tier reasoning_effort)
            )

          if is_binary(session_id) and session_id == evidence["learning_session_id"] and
               expected == actual,
             do: {:ok, worker},
             else: {:error, {:conflict, "Task Worker Session or model changed after routing"}}

        _ ->
          {:error, {:conflict, "Task has no unique routed Worker"}}
      end
    end
  end
end
