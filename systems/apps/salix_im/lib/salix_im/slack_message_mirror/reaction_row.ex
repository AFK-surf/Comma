defmodule SalixIM.SlackMessageMirror.ReactionRow do
  @moduledoc """
  Pure normalization for Slack reaction observations.

  Reactions are shared mirrored context, never Triage triggers. Identity is
  user, emoji, and event version so an add and a later remove both survive.
  `reaction_removed` tombstones that event. The reader applies events after
  the payload observation cut, in version order.

  Modeled in `tla/salix/SlackMirrorComponents.tla`.
  """

  alias SalixIM.SlackMessageMirror.Row

  @reaction ~r/\A[A-Za-z0-9_+\-]{1,100}\z/

  @spec from_event(map(), map()) :: {:ok, map()} | :ignore
  def from_event(connect, %{"event" => event}) when is_map(connect) and is_map(event) do
    with event_type when event_type in ["reaction_added", "reaction_removed"] <- event["type"],
         item when is_map(item) <- event["item"],
         true <- item["type"] == "message",
         tenant_id when tenant_id != "" <- trim(connect["tenant_id"]),
         workspace_id when workspace_id != "" <- trim(connect["workspace_id"]),
         channel_id when channel_id != "" <- trim(item["channel"]),
         message_ts when message_ts != "" <- trim(item["ts"]),
         {:ok, message_ts_us} <- Row.slack_ts_micros(message_ts),
         {:ok, state_ts_us} <- Row.slack_ts_micros(trim(event["event_ts"])),
         user_id when user_id != "" <- trim(event["user"]),
         reaction when reaction != "" <- trim(event["reaction"]),
         true <- Regex.match?(@reaction, reaction) do
      deleted? = event_type == "reaction_removed"

      {:ok,
       %{
         "event_date" => event_date(message_ts_us),
         "tenant_id" => tenant_id,
         "workspace_id" => workspace_id,
         "channel_id" => channel_id,
         "message_ts_us" => message_ts_us,
         "message_ts" => message_ts,
         "user_id" => user_id,
         "reaction" => reaction,
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

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
