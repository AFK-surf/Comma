defmodule AlertRouter.Workers.Remind do
  @moduledoc "One overdue reminder per handling revision, without scanning incidents."
  use Oban.Worker,
    queue: :alert_delivery,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args], states: :all]

  import Ecto.Query
  alias AlertRouter.Repo
  alias AlertRouter.Data.{Incident, EventRecord}
  alias AlertRouter.Slack.{Progress, Notices}

  def enqueue(incident) do
    if eligible?(incident) do
      seconds = if is_nil(incident.owner), do: 15 * 60, else: 30 * 60

      new(
        %{
          "incident_key" => incident.incident_key,
          "handling_revision" => incident.handling_revision
        },
        schedule_in: seconds
      )
      |> then(&Oban.insert(AlertRouter.Oban, &1))
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  def eligible?(incident) do
    Progress.enabled?() and incident.state == "firing" and incident.priority in ["P0", "P1"] and
      is_binary(incident.slack_root_ts) and Application.get_env(:alert_router, :mode) != :disabled
  end

  @impl true
  def perform(%Oban.Job{args: %{"incident_key" => key, "handling_revision" => revision}}) do
    Repo.transaction(fn ->
      incident = Repo.one(from(i in Incident, where: i.incident_key == ^key, lock: "FOR UPDATE"))

      if incident && eligible?(incident) && incident.handling_revision == revision do
        id = Notices.id(incident, "overdue", revision)

        unless Repo.get(EventRecord, id) do
          text =
            if is_nil(incident.owner),
              do: "仍无人接手，请在主卡点击“我来处理”。",
              else: "负责人 #{incident.owner} 已超过 30 分钟没有新的处理回报，请更新进展或转交。"

          event =
            Notices.record(incident, "overdue", text,
              identity: revision,
              handling_revision: revision,
              mention: incident.owner || "channel"
            )

          AlertRouter.Workers.DeliverTimeline.enqueue(event)
        end
      end

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
