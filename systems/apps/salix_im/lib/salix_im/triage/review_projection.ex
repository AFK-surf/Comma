defmodule SalixIM.Triage.ReviewProjection do
  @moduledoc """
  Pure, deterministic human-review projection for one evaluated Triage run.

  It creates Slack-shaped request data but owns no transport or executable
  intent. Review artifacts always carry an empty executed-action list and a
  typed zero-effect readback.
  """

  alias SalixIM.Triage.CanonicalJSON

  @spec slack(map(), map()) :: {:ok, map()} | {:error, term()}
  def slack(
        %{
          "schema" => "comma.triage-model-input.v3",
          "snapshot" => %{"source_authority" => authority}
        },
        %{"schema" => schema} = decision
      )
      when is_map(authority) and
             schema in ["comma.triage-product-decision.v1", "comma.triage-product-decision.v2"] do
    with {:ok, target} <- projected_target(authority) do
      artifact =
        %{
          "schema" => "comma.triage-product-outcome.v1",
          "delivery_mode" => "authoritative_obligations",
          "target" => target,
          "communication" => decision["communication"],
          "context_candidates" => decision["context_candidates"],
          "delegations" => decision["delegations"],
          "identity_interpretation" => decision["identity_interpretation"],
          "executed_actions" => [],
          "readback" => %{
            "status" => "authoritative_obligations_pending",
            "slack_writes" => 0,
            "worker_starts" => 0,
            "context_writes" => 0
          }
        }
        |> maybe_put_companion_reaction(decision)

      with {:ok, bytes} <- CanonicalJSON.encode(artifact) do
        {:ok, Map.put(artifact, "artifact_id", "triage-product-" <> CanonicalJSON.sha256(bytes))}
      end
    end
  end

  def slack(
        %{
          "schema" => "comma.triage-model-input.v3",
          "snapshot" => %{"source_authority" => authority}
        },
        %{"action" => action} = decision
      )
      when action in ["silence", "reply", "react", "delegate", "remember"] and
             is_map(authority) and is_map(decision) do
    with {:ok, target} <- projected_target(authority) do
      artifact = %{
        "schema" => "comma.triage-review-artifact.v2",
        "delivery_mode" => "review",
        "target" => target,
        "decision" => decision,
        "proposed_slack_request" => nil,
        "executed_actions" => [],
        "readback" => %{
          "status" => "review_only_not_sent",
          "slack_writes" => 0,
          "worker_starts" => 0,
          "memory_writes" => 0
        }
      }

      with {:ok, bytes} <- CanonicalJSON.encode(artifact) do
        {:ok, Map.put(artifact, "artifact_id", "triage-review-" <> CanonicalJSON.sha256(bytes))}
      end
    end
  end

  def slack(%{"source_authority" => authority, "events" => events}, decision)
      when is_map(authority) and is_list(events) and is_map(decision) do
    with {:ok, target_ts} <- target_ts(authority, events),
         {:ok, proposed_request} <- proposed_request(authority, target_ts, decision) do
      artifact = %{
        "schema" => "comma.triage-review-artifact.v1",
        "delivery_mode" => "review",
        "target" => %{
          "provider" => "slack",
          "workspace_id" => authority["workspace_id"],
          "channel_id" => authority["channel_id"],
          "thread_ts" => target_ts
        },
        "decision" => decision,
        "proposed_slack_request" => proposed_request,
        "executed_actions" => [],
        "readback" => %{
          "status" => "review_only_not_sent",
          "slack_writes" => 0,
          "worker_starts" => 0,
          "memory_writes" => 0
        }
      }

      with {:ok, bytes} <- CanonicalJSON.encode(artifact) do
        {:ok,
         Map.put(
           artifact,
           "artifact_id",
           "triage-review-" <> CanonicalJSON.sha256(bytes)
         )}
      end
    end
  end

  def slack(_input, _decision), do: {:error, :invalid_triage_review_input}

  defp maybe_put_companion_reaction(
         artifact,
         %{"schema" => "comma.triage-product-decision.v2"} = decision
       ),
       do: Map.put(artifact, "companion_reaction", decision["companion_reaction"])

  defp maybe_put_companion_reaction(artifact, _decision), do: artifact

  defp projected_target(
         %{
           "provider" => "slack",
           "workspace_ref" => workspace_ref,
           "bucket_ref" => bucket_ref,
           "endpoint_ref" => endpoint_ref,
           "scope_kind" => scope_kind
         } = authority
       )
       when map_size(authority) == 5 and scope_kind in ["channel", "thread"] and
              is_binary(workspace_ref) and workspace_ref != "" and is_binary(bucket_ref) and
              bucket_ref != "" and is_binary(endpoint_ref) and endpoint_ref != "" do
    {:ok,
     %{
       "provider" => "slack",
       "workspace_ref" => workspace_ref,
       "bucket_ref" => bucket_ref,
       "endpoint_ref" => endpoint_ref,
       "scope_kind" => scope_kind
     }}
  end

  defp projected_target(_authority), do: {:error, :invalid_triage_review_input}

  defp target_ts(%{"scope_kind" => "channel"}, events) do
    events
    |> Enum.reduce_while({:ok, nil}, fn event, {:ok, latest} ->
      message_ts = event["message_ts"]

      case slack_ts_key(message_ts) do
        {:ok, key} ->
          candidate = {key, message_ts}
          {:cont, {:ok, max_timestamp(latest, candidate)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, {_key, message_ts}} -> {:ok, message_ts}
      {:ok, nil} -> {:error, :missing_triage_review_target}
      {:error, _reason} = error -> error
    end
  end

  defp target_ts(authority, _events) do
    case authority["thread_ts"] do
      thread_ts when is_binary(thread_ts) and thread_ts not in ["", "__channel__"] ->
        with {:ok, _key} <- slack_ts_key(thread_ts), do: {:ok, thread_ts}

      _other ->
        {:error, :missing_triage_review_target}
    end
  end

  defp proposed_request(authority, target_ts, %{"action" => "reply", "text" => text})
       when is_binary(text) and text != "" do
    {:ok,
     %{
       "method" => "chat.postMessage",
       "body" => %{
         "channel" => authority["channel_id"],
         "thread_ts" => target_ts,
         "text" => text
       }
     }}
  end

  defp proposed_request(authority, target_ts, %{
         "action" => "react",
         "reaction" => reaction
       })
       when is_binary(reaction) and reaction != "" do
    {:ok,
     %{
       "method" => "reactions.add",
       "body" => %{
         "channel" => authority["channel_id"],
         "timestamp" => target_ts,
         "name" => reaction
       }
     }}
  end

  defp proposed_request(_authority, _target_ts, %{"action" => action})
       when action in ["silence", "delegate", "remember"],
       do: {:ok, nil}

  defp proposed_request(_authority, _target_ts, _decision),
    do: {:error, :invalid_triage_review_decision}

  defp max_timestamp(nil, candidate), do: candidate

  defp max_timestamp({key, _current_ts}, {candidate_key, _candidate_ts} = candidate)
       when candidate_key > key,
       do: candidate

  defp max_timestamp(current, _candidate), do: current

  defp slack_ts_key(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)(?:\.(\d{1,6}))?$/, value) do
      [_, seconds, fraction] ->
        {:ok, {String.to_integer(seconds), micros(fraction)}}

      [_, seconds] ->
        {:ok, {String.to_integer(seconds), 0}}

      _other ->
        {:error, :invalid_slack_timestamp}
    end
  end

  defp slack_ts_key(_value), do: {:error, :invalid_slack_timestamp}

  defp micros(fraction) do
    fraction
    |> String.slice(0, 6)
    |> String.pad_trailing(6, "0")
    |> String.to_integer()
  end
end
