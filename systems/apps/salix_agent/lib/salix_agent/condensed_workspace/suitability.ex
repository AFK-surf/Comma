defmodule SalixAgent.CondensedWorkspace.Suitability do
  @moduledoc """
  The decision-model check of an Agent's Condensed Workspace update before
  it is applied (docs/agent-runtime.md#condensed-workspace).

  Each `add` and `replace` statement is one independent yes/no question: is
  this statement a current fact that other Agents of the Group need? A
  statement below the minimum (default 15%) rejects the whole update, and
  nothing is applied.

  The question is asked positively, under a neutral key. Measured against
  jev-1.13 on 24 labelled statements (2026-10-05), the negative form ("is it
  unsuitable?") scored suitable facts at 0.74-0.95, so it rejected nearly
  every update. The positive form scored facts at 0.27-0.60 and unsuitable
  statements at 0.03-0.08. The rejection names the statements and carries a
  `rejection_id`. The Agent makes the final decision: the same operations
  with `force_override` set to that id are applied without a second check.

  The id is derived from the Group, the Session and the exact operations.
  It binds the override to the update that was rejected, so an override
  cannot carry other content. It is an acknowledgment, not a credential: the
  Agent may write without any check by design.

  A check that cannot run (no provider, refused budget, timeout or error)
  does not block the update. Humans editing in Comma are not checked.
  """

  alias SalixAgent.Decide
  alias SalixStore.CondensedWorkspaces, as: Store

  @questions_per_call 8
  @default_deadline_ms 5_000
  @default_suitable_min_bp 1_500

  @doc """
  `:ok`, or `{:rejected, rejection_id, [%{"index" => i, "text" => text}]}`.
  `index` is the 1-based position of the operation in the update.
  """
  def check(operations, group_id, ctx) do
    statements =
      operations
      |> Enum.with_index(1)
      |> Enum.filter(fn {operation, _index} -> operation["op"] in ["add", "replace"] end)

    with [_ | _] <- statements,
         {:ok, _config} <- Decide.config(),
         {:ok, workspace} <- Store.get(group_id) do
      deadline = SystemsClock.monotonic_time(:millisecond) + deadline_ms()

      rejected =
        statements
        |> Enum.chunk_every(@questions_per_call)
        |> SystemsClock.async_stream(&ask(&1, workspace, ctx, deadline),
          timeout: deadline_ms() + 1_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, rejected} -> rejected
          {:exit, _reason} -> []
        end)

      case rejected do
        [] -> :ok
        _ -> {:rejected, rejection_id(operations, group_id, ctx), rejected}
      end
    else
      _ -> :ok
    end
  end

  @doc "The id that a `force_override` of exactly these operations must carry."
  def rejection_id(operations, group_id, ctx) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({group_id, to_string(ctx[:session_id]), operations}, [
          :deterministic
        ])
      )
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    "cwr_" <> digest
  end

  @doc false
  # `statements` are `{operation, index}` pairs with 1-based indexes.
  def request(statements, workspace) do
    %{
      "state" => %{
        "condensed_workspace" => Store.render(workspace.statements),
        "proposed_statements" =>
          Map.new(statements, fn {operation, index} -> {key(index), operation["text"]} end)
      },
      "questions" =>
        Map.new(statements, fn {_operation, index} -> {key(index), question(index)} end)
    }
  end

  defp ask(statements, workspace, ctx, deadline) do
    args = request(statements, workspace)

    case Decide.condensed_workspace_call(args, ctx, deadline) do
      {:ok, %{"answers" => answers}} ->
        statements
        |> Enum.filter(fn {_operation, index} ->
          probability(answers, key(index)) < suitable_min()
        end)
        |> Enum.map(fn {operation, index} -> %{"index" => index, "text" => operation["text"]} end)

      _ ->
        []
    end
  end

  defp key(index), do: "statement_#{index}"

  defp probability(answers, key) do
    case answers[key] do
      %{"probability_bp" => bp} when is_integer(bp) -> bp
      # A missing answer cannot reject a statement.
      _ -> 10_000
    end
  end

  defp question(index) do
    %{
      "type" => "noul",
      "instructions" =>
        "The state has a Group's Condensed Workspace (a short shared list of current facts that every Agent of the Group keeps in context) and statements an Agent proposes to add to it. " <>
          "Consider proposed statement #{key(index)}. Answer true when it is a short, current fact that other Agents of the Group need, such as a decision, an owner, a status, a constraint, a deadline, a preference, or where something is. " <>
          "Answer false when it is a work log, a plan step, a status that matters only to the writing Session, a question, an instruction to Agents, raw data, a greeting, or a duplicate of an existing statement.",
      "criteria" => %{
        "true" =>
          "A current, shared fact that other Agents need: a decision, owner, status, constraint, deadline, preference, or location.",
        "false" =>
          "Not a shared fact: a work log, plan step, Session-only status, question, instruction to Agents, raw data, greeting, or duplicate of an existing statement."
      }
    }
  end

  defp deadline_ms, do: setting(:suitability_deadline_ms, @default_deadline_ms)
  defp suitable_min, do: setting(:suitable_min_bp, @default_suitable_min_bp)

  defp setting(key, default) do
    case SystemsRuntime.get_env(:salix_agent, :condensed_workspace, [])[key] do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
