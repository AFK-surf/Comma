defmodule AlertRouter.Slack.Progress do
  @moduledoc "Explicit thread reports update presentation without changing source lifecycle."

  import Ecto.Query
  alias AlertRouter.{Repo, Telemetry}
  alias AlertRouter.Data.Incident
  alias AlertRouter.Workers.DeliverIncident

  def enabled? do
    config = Application.get_env(:alert_router, :slack_progress, [])

    Enum.all?([:signing_secret, :team_id, :app_id], fn key ->
      is_binary(config[key]) and config[key] != ""
    end)
  end

  def accept(payload) do
    Telemetry.observe(:progress, :slack, fn -> accept_event(payload) end)
  end

  defp accept_event(%{"type" => "event_callback", "event" => event} = payload)
       when is_map(event) do
    config = Application.get_env(:alert_router, :slack_progress, [])

    if enabled?() and payload["team_id"] == config[:team_id] and
         payload["api_app_id"] == config[:app_id] and
         Application.get_env(:alert_router, :mode) != :disabled do
      report(event)
    else
      {:error, :unauthorized}
    end
  end

  defp accept_event(_), do: {:ok, :ignored}

  defp report(
         %{
           "type" => "message",
           "channel" => channel,
           "thread_ts" => root_ts,
           "ts" => ts,
           "text" => text
         } = event
       )
       when is_binary(channel) and is_binary(root_ts) and is_binary(ts) and
              is_binary(text) and byte_size(text) <= 16_000 do
    author = event["user"] || event["bot_id"]

    with {:ok, text, source} <- report_text(text, event),
         true <- event["subtype"] in [nil, "bot_message"],
         true <- Regex.match?(~r/\AC[A-Z0-9]{1,32}\z/, channel),
         true <- is_binary(author) and Regex.match?(~r/\A[UWB][A-Z0-9]{1,32}\z/, author),
         true <- String.valid?(text) and String.length(text) in 1..1800,
         true <- String.trim(text) != "",
         {:ok, timestamp} <- timestamp(ts),
         {:ok, root_timestamp} <- timestamp(root_ts),
         true <- timestamp > root_timestamp do
      persist(channel, root_ts, %{
        "text" => String.trim(text),
        "author" => author,
        "source" => source,
        "ts" => ts,
        "timestamp" => timestamp
      })
    else
      _ -> {:ok, :ignored}
    end
  end

  defp report(_), do: {:ok, :ignored}

  defp report_text("告警进展\n" <> text, _) when byte_size(text) <= 4000,
    do: {:ok, text, "explicit"}

  defp report_text(text, event) do
    config = Application.get_env(:alert_router, :slack_progress, [])
    bot = config[:investigator_bot_id]

    event_app =
      case event do
        %{"app_id" => app} when is_binary(app) -> app
        %{"bot_profile" => %{"app_id" => app}} -> app
        _ -> nil
      end

    if is_binary(event_app) and event_app != config[:app_id] and is_binary(bot) and
         Regex.match?(~r/\AB[A-Z0-9]{1,32}\z/, bot) and event["bot_id"] == bot and
         String.valid?(text) do
      # Bound bot reports without requiring the investigator to adopt a prefix.
      # Shortening never promotes the report into verified evidence.
      shortened =
        text
        |> String.graphemes()
        |> Enum.reduce_while("", fn char, acc ->
          if byte_size(acc <> char) <= 3900 and String.length(acc <> char) <= 1750,
            do: {:cont, acc <> char},
            else: {:halt, acc}
        end)

      suffix = if shortened == text, do: "", else: "…（完整回报见原线程）"
      {:ok, shortened <> suffix, "investigator"}
    else
      :ignored
    end
  end

  defp persist(channel, root_ts, progress) do
    Repo.transaction(fn ->
      incident =
        Repo.one(
          from(i in Incident,
            where: i.channel_id == ^channel and i.slack_root_ts == ^root_ts,
            lock: "FOR UPDATE"
          )
        )

      cond do
        is_nil(incident) ->
          :ignored

        progress["timestamp"] <= (incident.progress["timestamp"] || 0) ->
          :stale

        progress["source"] == "investigator" and progress["text"] == incident.progress["text"] and
            progress["author"] == incident.progress["author"] ->
          # Keep ordering current without restarting handling or publishing the same report.
          incident
          |> Ecto.Changeset.change(progress: progress)
          |> Repo.update!()

          :unchanged

        true ->
          updated = update_card(incident, %{progress: progress})

          if progress["source"] == "explicit" do
            AlertRouter.Slack.Notices.record(
              updated,
              "progress",
              "处理进展 · #{progress["author"]}：#{String.slice(progress["text"], 0, 600)}"
            )
          end

          :accepted
      end
    end)
  end

  def update_card(incident, changes) do
    revision = incident.desired_revision + 1

    # An unassigned incident still needs a human, even while bot reports arrive.
    handling_revision =
      incident.handling_revision +
        if(
          Map.has_key?(changes, :owner) or
            (Map.has_key?(changes, :progress) and is_binary(incident.owner)),
          do: 1,
          else: 0
        )

    changes =
      Map.merge(changes, %{
        desired_revision: revision,
        handling_revision: handling_revision
      })

    changes =
      if incident.delivery_state in ["pending", "posted"],
        do: Map.merge(changes, %{delivery_state: "pending", last_error_class: nil}),
        else: changes

    updated = incident |> Ecto.Changeset.change(changes) |> Repo.update!()

    %{
      "incident_key" => incident.incident_key,
      "render_revision" => revision,
      "route_revision" => incident.route_revision
    }
    |> DeliverIncident.new()
    |> then(&Oban.insert!(AlertRouter.Oban, &1))

    updated
  end

  defp timestamp(ts) do
    case Regex.run(~r/\A([0-9]{10})\.([0-9]{6})\z/, ts) do
      [_, seconds, micros] ->
        {:ok, String.to_integer(seconds) * 1_000_000 + String.to_integer(micros)}

      _ ->
        :error
    end
  end
end
