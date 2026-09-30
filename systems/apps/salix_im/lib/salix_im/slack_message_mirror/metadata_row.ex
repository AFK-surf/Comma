defmodule SalixIM.SlackMessageMirror.MetadataRow do
  @moduledoc """
  Pure normalization for Slack message-metadata observations.

  Metadata updates do not change `edited.ts`, so they are stored beside the
  message row and overlaid at read time.
  """

  alias SalixIM.SlackMessageMirror.Row
  alias SalixIM.Triage.CanonicalJSON

  @spec from_event(map(), map()) :: {:ok, map()} | :ignore
  def from_event(connect, %{"event" => event}) when is_map(connect) and is_map(event) do
    with event_type
         when event_type in [
                "message_metadata_posted",
                "message_metadata_updated",
                "message_metadata_deleted"
              ] <- event["type"],
         tenant_id when tenant_id != "" <- trim(connect["tenant_id"]),
         workspace_id when workspace_id != "" <- trim(connect["workspace_id"]),
         channel_id when channel_id != "" <- trim(event["channel_id"] || event["channel"]),
         message_ts when message_ts != "" <- trim(event["message_ts"] || event["ts"]),
         {:ok, message_ts_us} <- Row.slack_ts_micros(message_ts),
         {:ok, state_ts_us} <- Row.slack_ts_micros(trim(event["event_ts"])) do
      deleted? = event_type == "message_metadata_deleted"
      metadata = if(is_map(event["metadata"]), do: event["metadata"], else: %{})

      {:ok,
       %{
         "event_date" => event_date(message_ts_us),
         "tenant_id" => tenant_id,
         "workspace_id" => workspace_id,
         "channel_id" => channel_id,
         "message_ts_us" => message_ts_us,
         "message_ts" => message_ts,
         "version" => Row.version(state_ts_us, deleted?),
         "deleted" => deleted?,
         "metadata" => CanonicalJSON.encode!(metadata),
         "ingest_source" => "webhook"
       }}
    else
      _invalid -> :ignore
    end
  end

  def from_event(_connect, _envelope), do: :ignore

  defp event_date(message_ts_us) do
    message_ts_us
    |> div(1_000_000)
    |> DateTime.from_unix!()
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
