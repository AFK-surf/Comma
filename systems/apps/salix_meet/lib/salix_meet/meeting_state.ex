defmodule SalixMeet.MeetingState do
  @moduledoc """
  Canonical constructors for durable meeting state.

  Provider entry points discover meetings differently, but every provider-backed
  meeting must persist the same runtime identity and delivery shape before it
  can be dispatched. Keeping that shape here prevents a new entry point from
  omitting credentials, confusing the durable agent id with its session id, or
  choosing a non-standard artifact root.
  """

  alias SalixMeet.RuntimeEvents

  @doc """
  Build the complete state for a Slack-backed meeting.

  `meeting_agent` is the durable record returned by `SalixMeet.Runtime`; `attrs`
  is string-keyed and supplies the provider/source-specific values. Required
  attributes are `tenant_id`, `group_id`, `connect_id`, `slack_ref`,
  `meet_url`, `title`, `bot_name`, `caption_language`, `start_at`, `end_at`, and
  `source`. `status` defaults to `"provisioning"`; `callback_url` is copied when
  present.
  """
  @spec new_slack(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def new_slack(meeting_id, meeting_agent, attrs)
      when is_binary(meeting_id) and is_map(meeting_agent) and is_map(attrs) do
    new_provider(meeting_id, meeting_agent, attrs, "slack", "slack_ref")
  end

  @doc "Build the complete state for a Feishu-triggered Google Meet."
  @spec new_feishu(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def new_feishu(meeting_id, meeting_agent, attrs)
      when is_binary(meeting_id) and is_map(meeting_agent) and is_map(attrs) do
    new_provider(meeting_id, meeting_agent, attrs, "feishu", "feishu_ref")
  end

  defp new_provider(meeting_id, meeting_agent, attrs, provider, provider_ref_key) do
    with {:ok, runtime_source} <- SalixMeet.MeetingRuntimePolicy.select(attrs) do
      state = %{
        "tenant_id" => Map.fetch!(attrs, "tenant_id"),
        "group_id" => Map.fetch!(attrs, "group_id"),
        "meeting_agent_id" => Map.fetch!(meeting_agent, "meeting_agent_id"),
        "meeting_session_id" => Map.fetch!(meeting_agent, "meeting_session_id"),
        "provider" => provider,
        "connect_id" => Map.fetch!(attrs, "connect_id"),
        "meeting_id" => meeting_id,
        "meet_url" => Map.fetch!(attrs, "meet_url"),
        "title" => Map.fetch!(attrs, "title"),
        "caption_language" => Map.fetch!(attrs, "caption_language"),
        "bot_name" => Map.fetch!(attrs, "bot_name"),
        "start_at" => Map.fetch!(attrs, "start_at"),
        "end_at" => Map.fetch!(attrs, "end_at"),
        "status" => Map.get(attrs, "status", "provisioning"),
        "runtime_token" => runtime_token(),
        "runtime_ref" => Map.fetch!(meeting_agent, "meeting_session_id"),
        "runtime_source" => runtime_source,
        "runtime_policy" => %{"source" => runtime_source},
        "artifact_root" => RuntimeEvents.artifact_root(meeting_id),
        provider_ref_key => Map.fetch!(attrs, provider_ref_key),
        "source" => Map.fetch!(attrs, "source"),
        "captions" => [],
        "chats" => [],
        "artifacts" => %{},
        "delivery" => %{}
      }

      {:ok,
       state
       |> maybe_put("callback_url", attrs)
       |> maybe_put("compute_environment_id", attrs)
       |> maybe_put("workload_id", attrs)
       |> maybe_put("attempt", attrs)}
    end
  end

  defp runtime_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp maybe_put(state, key, attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(state, key, value)
      :error -> state
    end
  end
end
