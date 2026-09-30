defmodule SalixAgent.MemoryConsultation do
  @moduledoc """
  Bounded execution for the Router-only `memory.ask_worker` tool.

  Conversation discovery returns candidate Worker Session bindings. Each
  candidate is re-resolved by its Conversation owner before the Worker owner
  performs the consultation. The fan-out/deadline contract is modeled in
  `tla/salix/MemoryAskWorker.tla`.
  """

  alias SalixAgent.{GroupContext, MemoryConsultationSource}

  @max_targets 10
  @target_timeout_ms 25_000

  @spec ask(String.t(), String.t(), [map()], map()) :: map()
  def ask(keywords, question, conversation_refs, ctx)
      when is_binary(keywords) and is_binary(question) and is_list(conversation_refs) and
             is_map(ctx) do
    with :ok <- authorize_router(ctx),
         :ok <- authorize_enabled(ctx),
         {:ok, discovery} <-
           MemoryConsultationSource.search(
             ctx.group_id,
             keywords,
             conversation_refs,
             @max_targets + 1
           ) do
      {targets, overflow} = select_targets(discovery.targets)

      results =
        targets
        |> Task.async_stream(
          &consult(&1, question, ctx),
          max_concurrency: @max_targets,
          ordered: true,
          timeout: @target_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.zip(targets)
        |> Enum.map(fn
          {{:ok, result}, _target} -> result
          {{:exit, :timeout}, target} -> target_result(target, "timed_out")
          {{:exit, {:timeout, _call}}, target} -> target_result(target, "timed_out")
          {{:exit, _reason}, target} -> target_result(target, "failed")
        end)

      %{
        "keywords" => keywords,
        "question" => question,
        "results" => results,
        "truncated" => discovery.truncated == true or overflow
      }
    else
      {:error, reason} ->
        %{
          "keywords" => keywords,
          "question" => question,
          "results" => [],
          "truncated" => false,
          "error" => format(reason)
        }
    end
  end

  defp authorize_router(%{role: "router", group_id: group_id, agent_id: agent_id})
       when is_binary(group_id) and group_id != "" and is_binary(agent_id) and agent_id != "",
       do: :ok

  defp authorize_router(_ctx), do: {:error, :router_only}

  @doc false
  def enabled?(ctx) when is_map(ctx) do
    tenant_id = Map.get(ctx, :tenant_id) || Map.get(ctx, "tenant_id")
    group_id = Map.get(ctx, :group_id) || Map.get(ctx, "group_id")

    if is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" do
      match?(
        {:ok, %{"memory_ask_worker_enabled" => true}},
        GroupContext.get(group_id, tenant_id)
      )
    else
      false
    end
  end

  def enabled?(_ctx), do: false

  defp authorize_enabled(ctx) do
    if enabled?(ctx), do: :ok, else: {:error, :memory_ask_worker_disabled}
  end

  defp select_targets(targets) do
    unique =
      targets
      |> Enum.sort_by(&Map.get(&1, :rank_at, 0), :desc)
      |> Enum.uniq_by(&{&1.agent_id, &1.session_id})

    {Enum.take(unique, @max_targets), length(unique) > @max_targets}
  end

  defp consult(target, query, ctx) do
    request_id = "memory-consultation-" <> SalixStore.ULID.generate()

    case MemoryConsultationSource.consult(
           ctx.group_id,
           target,
           query,
           request_id,
           timeout: @target_timeout_ms,
           requester_agent_id: ctx.agent_id
         ) do
      {:ok, %{"status" => status} = result} when is_binary(status) ->
        target_result(target, status, Map.delete(result, "status"))

      {:error, :busy} ->
        target_result(target, "busy")

      {:error, :timeout} ->
        target_result(target, "timed_out")

      {:error, :no_answer} ->
        target_result(target, "no_answer")

      {:error, :not_found} ->
        target_result(target, "unavailable")

      {:error, :participant_binding_changed} ->
        target_result(target, "unavailable")

      {:error, reason} ->
        target_result(target, "failed", %{"error" => format(reason)})
    end
  end

  defp target_result(target, status, extra \\ %{}) do
    %{
      "conversation_ref" => target.conversation_ref,
      "worker_role" => target.worker_role,
      "runtime_kind" => target.runtime_kind,
      "status" => status
    }
    |> Map.merge(extra)
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
