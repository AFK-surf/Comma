defmodule SalixMeet.SlackThreadIndex do
  @moduledoc """
  Immutable ownership fence for a Slack meeting thread.

  The index is scoped by tenant, group, connect, channel, and thread. Once a
  meeting claims that scope, a different meeting can neither replace nor reuse
  it, including after the original meeting reaches a terminal state.
  """

  alias SalixStore.{Crypto, S3}

  @provider "slack"

  @spec fetch(map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def fetch(owner, channel, thread) when is_map(owner) do
    with {:ok, scope} <- scope(owner, channel, thread),
         {:ok, %{body: body}} <- S3.get(key(scope)),
         {:ok, record} <- decode_record(body),
         :ok <- validate_record(record, scope) do
      {:ok, record}
    end
  end

  @spec claim(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, {:thread_owned, String.t()} | term()}
  def claim(owner, channel, thread, meeting_id) when is_map(owner) do
    with {:ok, scope} <- scope(owner, channel, thread),
         meeting_id when meeting_id != "" <- trim(meeting_id) do
      record =
        scope
        |> Map.put("provider", @provider)
        |> Map.put("meeting_id", meeting_id)
        |> Map.put("created_at", System.system_time(:second))

      claim_once(scope, record, 1)
    else
      "" -> {:error, :invalid_meeting_id}
      {:error, _} = error -> error
    end
  end

  defp claim_once(scope, record, retries) do
    case S3.put(key(scope), Jason.encode!(record), if_none_match: "*") do
      {:ok, _} ->
        {:ok, record}

      {:error, :precondition_failed} ->
        resolve_existing_claim(scope, record["meeting_id"])

      {:error, {:ambiguous, _}} when retries > 0 ->
        case resolve_existing_claim(scope, record["meeting_id"]) do
          {:error, :not_found} -> claim_once(scope, record, retries - 1)
          resolved -> resolved
        end

      {:error, {:ambiguous, _}} = error ->
        case resolve_existing_claim(scope, record["meeting_id"]) do
          {:error, :not_found} -> error
          resolved -> resolved
        end

      {:error, _} = error ->
        error
    end
  end

  defp resolve_existing_claim(scope, meeting_id) do
    case fetch(scope, scope["channel_id"], scope["thread_ts"]) do
      {:ok, %{"meeting_id" => ^meeting_id} = record} ->
        {:ok, record}

      {:ok, %{"meeting_id" => existing_id}} ->
        {:error, {:thread_owned, existing_id}}

      {:error, _} = error ->
        error
    end
  end

  defp decode_record(body) do
    case Jason.decode(body) do
      {:ok, record} when is_map(record) -> {:ok, record}
      _ -> {:error, :invalid_slack_thread_index}
    end
  end

  defp validate_record(record, scope) do
    fields = ~w(tenant_id group_id connect_id channel_id thread_ts)

    if record["provider"] == @provider and trim(record["meeting_id"]) != "" and
         Enum.all?(fields, &(record[&1] == scope[&1])) do
      :ok
    else
      {:error, :invalid_slack_thread_index}
    end
  end

  defp scope(owner, channel, thread) do
    scope = %{
      "tenant_id" => trim(owner["tenant_id"] || owner[:tenant_id]),
      "group_id" => trim(owner["group_id"] || owner[:group_id]),
      "connect_id" => trim(owner["connect_id"] || owner[:connect_id]),
      "channel_id" => trim(channel),
      "thread_ts" => trim(thread)
    }

    if Enum.all?(scope, fn {_key, value} -> value != "" end),
      do: {:ok, scope},
      else: {:error, :invalid_slack_thread_scope}
  end

  defp key(scope) do
    digest =
      Crypto.hex([
        scope["tenant_id"],
        <<0>>,
        scope["group_id"],
        <<0>>,
        scope["connect_id"],
        <<0>>,
        scope["channel_id"],
        <<0>>,
        scope["thread_ts"]
      ])

    "meet/sources/slack/#{scope["group_id"]}/#{digest}.json"
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
