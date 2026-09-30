defmodule AlertRouter.RuntimeEpisode do
  @moduledoc """
  Pure reducer for one exact producer-owned fault episode.

  Every receipt carries its episode start and cumulative priority. Thus a newer
  snapshot is sufficient even when old segments are backfilled or notifications
  reorder. Join priority and recovery from the existing incident; Ingest persists the
  incident and its delivery job together. No separate checkpoint is needed.
  TLA: `tla/alert_router/RuntimeEpisode.tla::Consume`.
  """

  @type result :: {:ok, map(), AlertRouter.CanonicalEvent.t() | nil} | {:error, atom()}

  @spec consume(map(), map(), map()) :: result()
  def consume(state, fact, metadata \\ %{}) when is_map(state) and is_map(fact) do
    with :ok <- validate(fact),
         :ok <- same_execution(state, fact) do
      next = Map.take(fact, ~w(identity episode_id started_at priority))
      recovered = fact["kind"] == "runtime_recovered" or state["recovered"] == true
      priority = if state["priority"] == "P0", do: "P0", else: fact["priority"]

      next =
        Map.merge(next, %{
          "priority" => priority,
          "recovered" => recovered
        })

      if state["priority"] == priority and state["recovered"] == recovered do
        {:ok, next, nil}
      else
        with {:ok, event} <- event(next, fact, metadata), do: {:ok, next, event}
      end
    end
  end

  defp event(state, fact, metadata) do
    [environment, tenant, agent, session, dispatch, execution] = state["identity"]
    recovered? = state["recovered"]
    exhausted? = state["priority"] == "P0"
    {:ok, started, _} = DateTime.from_iso8601(state["started_at"])
    {:ok, observed, _} = DateTime.from_iso8601(fact["observed_at"])

    trigger = if exhausted?, do: "recovery_exhausted", else: "runtime_failed"

    AlertRouter.CanonicalEvent.build(%{
      schema_version: 1,
      source: "salix_runtime",
      source_account: environment,
      source_identity:
        ["alert-router.v1", "salix_runtime"] ++
          state["identity"] ++ [state["episode_id"]],
      policy_identity: ["salix_runtime", "external_execution"],
      source_state: if(recovered?, do: "runtime_recovered", else: trigger),
      state: if(recovered?, do: "resolved", else: "firing"),
      recovery_status: if(recovered?, do: "verified", else: "not_applicable"),
      environment: environment,
      priority: state["priority"],
      team: "comma",
      service: "salix_agent",
      family: "availability",
      started_at: started,
      observed_at: observed,
      ended_at: if(recovered?, do: observed),
      summary: if(exhausted?, do: "Agent 自动恢复耗尽", else: "Agent runtime 中断"),
      impact:
        if(recovered?,
          do: "本次执行中断已恢复；不代表整个任务已完成。",
          else:
            if(exhausted?, do: "自动恢复已停止，受影响的 execution 需要人工处理。", else: "执行曾发生中断；该失败不代表自动恢复耗尽。")
        ),
      latest:
        if(recovered?,
          do: "同一 execution 的 runtime_recovered 已确认恢复；不表示整个任务完成。",
          else: if(exhausted?, do: "需要人工介入。", else: "等待同一故障的恢复证据。")
        ),
      evidence_values:
        %{
          "tenant" => tenant,
          "agent" => agent,
          "session" => session,
          "dispatch" => dispatch,
          "execution" => execution,
          "agent_group" => metadata["group_id"],
          "cluster" => metadata["cluster"],
          "trigger_error" => trigger,
          "observed" => "1",
          "threshold" => "单次故障",
          "duration" => "单次事件"
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end),
      links:
        %{
          "incident" => metadata["incident_url"],
          "runbook" =>
            "https://github.com/AFK-surf/Comma/blob/main/docs/observability.md"
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
    })
  end

  defp same_execution(%{"identity" => identity, "episode_id" => episode}, %{
         "identity" => identity,
         "episode_id" => episode
       }),
       do: :ok

  defp same_execution(%{"identity" => _}, _), do: {:error, :execution_identity_mismatch}
  defp same_execution(_, _), do: :ok

  defp validate(%{
         "identity" => [environment, tenant, agent, session, dispatch, execution],
         "record_id" => record,
         "episode_id" => episode,
         "started_at" => started,
         "priority" => priority,
         "kind" => kind,
         "observed_at" => at
       }) do
    cond do
      environment not in ["staging", "production"] ->
        {:error, :invalid_environment}

      kind not in ["runtime_failed", "recovery_exhausted", "runtime_recovered"] ->
        {:error, :invalid_kind}

      not Enum.all?([tenant, agent, session, dispatch, execution], &reference?/1) ->
        {:error, :invalid_identity}

      not Enum.all?(
        [record, episode],
        &(is_binary(&1) and Regex.match?(~r/^[0-7][0-9A-HJKMNP-TV-Z]{25}$/, &1))
      ) ->
        {:error, :invalid_record_id}

      not valid_time?(at) or not valid_time?(started) ->
        {:error, :invalid_observed_at}

      priority not in ["P0", "P1"] ->
        {:error, :invalid_priority}

      true ->
        :ok
    end
  end

  defp validate(_), do: {:error, :invalid_runtime_fact}

  defp reference?(value),
    do:
      is_binary(value) and byte_size(value) in 1..160 and
        Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:@\/-]*$/, value)

  defp valid_time?(value) when is_binary(value),
    do: match?({:ok, _, 0}, DateTime.from_iso8601(value))

  defp valid_time?(_), do: false
end

