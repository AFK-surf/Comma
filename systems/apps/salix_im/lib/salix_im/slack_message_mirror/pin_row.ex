defmodule SalixIM.SlackMessageMirror.PinRow do
  @moduledoc """
  Pure normalization for Slack pin observations.

  Pins mutate independently of `edited.ts`, so they cannot share the message
  version. A `pin_removed` tombstone is the current unpinned state.
  `pinned_ts` is the pin event's time, never the message timestamp.

  Modeled in `tla/salix/SlackMirrorComponents.tla`.
  """

  alias SalixIM.SlackMessageMirror.Row

  @spec from_event(map(), map()) :: {:ok, map()} | :ignore
  def from_event(connect, %{"event" => event}) when is_map(connect) and is_map(event) do
    with event_type when event_type in ["pin_added", "pin_removed"] <- event["type"],
         item when is_map(item) <- event["item"],
         true <- item["type"] == "message",
         tenant_id when tenant_id != "" <- trim(connect["tenant_id"]),
         workspace_id when workspace_id != "" <- trim(connect["workspace_id"]),
         channel_id when channel_id != "" <- trim(item["channel"] || event["channel_id"]),
         message_ts when message_ts != "" <- trim(item["ts"]),
         {:ok, message_ts_us} <- Row.slack_ts_micros(message_ts),
         {:ok, state_ts_us} <- Row.slack_ts_micros(trim(event["event_ts"])),
         user_id when user_id != "" <- trim(event["user"]) do
      deleted? = event_type == "pin_removed"

      {:ok,
       %{
         "event_date" => event_date(message_ts_us),
         "tenant_id" => tenant_id,
         "workspace_id" => workspace_id,
         "channel_id" => channel_id,
         "message_ts_us" => message_ts_us,
         "message_ts" => message_ts,
         "pinned_by" => user_id,
         "pinned_ts" => pinned_ts(event),
         "version" => Row.version(state_ts_us, deleted?),
         "deleted" => deleted?,
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

  # Slack's pin event carries `pinned_info.pinned_ts` as unix seconds. Fall
  # back to `event_ts` when the field is missing so a later read never has to
  # invent the pin time from the message timestamp.
  defp pinned_ts(%{"pinned_info" => %{"pinned_ts" => ts}}), do: stringify_ts(ts)
  defp pinned_ts(event), do: trim(event["event_ts"])

  defp stringify_ts(ts) when is_integer(ts) and ts >= 0, do: Integer.to_string(ts)
  defp stringify_ts(ts) when is_binary(ts), do: trim(ts)
  defp stringify_ts(_other), do: ""

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
