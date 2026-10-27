defmodule BridgeForTeams.DailyBrief.Dashboard do
  @moduledoc """
  What the admin page shows about a Swarm's daily brief, from its runs.

  Only counts, statuses, and dates leave this module, never a brief's text.
  Each function is a fixed number of indexed queries, bounded by the window
  and by `@max_runs`.
  """

  import Ecto.Query

  alias BridgeForTeams.Repo
  alias BridgeForTeams.DailyBrief.Delivery

  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefRun, DailyBriefSetting, User}

  @max_runs 30
  # The longest run of days off the dashboard looks past.
  @calendar_lookahead_days 31

  @doc "The last team brief, today's member briefs by state, and the next brief time."
  @spec today(DailyBriefSetting.t(), DateTime.t()) :: map()
  def today(%DailyBriefSetting{} = settings, now) do
    team_pass =
      Repo.one(
        from(r in DailyBriefRun,
          where: r.project_id == ^settings.project_id and r.kind == "team_brief",
          order_by: [desc: r.created_at],
          limit: 1
        )
      )

    briefs =
      Repo.all(
        from(r in DailyBriefRun,
          where:
            r.project_id == ^settings.project_id and r.kind == "personal_brief" and
              r.created_at >= ^DateTime.add(now, -86_400),
          group_by: r.status,
          select: {r.status, count(r.id)}
        )
      )
      |> Map.new()

    members =
      Repo.all(
        from(m in DailyBriefMember,
          where: m.org_id == ^settings.org_id and m.enabled,
          select: %{
            timezone: m.timezone,
            deliver_at: m.deliver_at,
            requested: not is_nil(m.brief_requested_at)
          }
        )
      )

    %{
      "team_pass" =>
        team_pass &&
          %{
            "status" => team_pass.status,
            "at" => team_pass.updated_at,
            "error" => short(team_pass.error)
          },
      "sent" => Map.get(briefs, "completed", 0),
      "pending" => Map.get(briefs, "pending", 0),
      "failed" => Map.get(briefs, "failed", 0),
      "requested" => Enum.count(members, & &1.requested),
      "members" => length(members),
      "next_brief_at" =>
        members |> Enum.map(&next_at(settings, &1, now)) |> Enum.reject(&is_nil/1) |> min_at()
    }
  end

  @doc "The Swarm's latest runs, newest first, with the member's name for personal ones."
  @spec runs(DailyBriefSetting.t()) :: [map()]
  def runs(%DailyBriefSetting{} = settings) do
    Repo.all(
      from(r in DailyBriefRun,
        left_join: m in DailyBriefMember,
        on: m.id == r.member_id,
        left_join: u in User,
        on: u.id == m.user_id,
        where: r.project_id == ^settings.project_id,
        order_by: [desc: r.created_at],
        limit: @max_runs,
        select: %{
          id: r.id,
          kind: r.kind,
          status: r.status,
          member_id: r.member_id,
          member: coalesce(u.name, u.email),
          tokens: r.input_tokens + r.output_tokens,
          error: r.error,
          coverage: r.coverage,
          at: r.created_at
        }
      )
    )
    |> Enum.map(fn run ->
      %{
        "id" => run.id,
        "kind" => run.kind,
        "status" => run.status,
        "member_id" => run.member_id,
        "member" => run.member,
        "tokens" => run.tokens,
        "error" => short(run.error),
        "complete" => run.coverage["shared_complete"] != false,
        # Not when Slack refused the member for good.
        "retryable" =>
          run.kind == "personal_brief" and run.status in ["pending", "failed"] and
            Delivery.transient?(run.error || ""),
        "at" => run.at
      }
    end)
  end

  @doc "Per member: when Slack last took a brief in `days`, and a waiting request."
  @spec member_activity(DailyBriefSetting.t(), DateTime.t(), pos_integer()) :: %{
          binary() => map()
        }
  def member_activity(%DailyBriefSetting{} = settings, now, days) do
    from_at = DateTime.add(now, -days * 86_400)

    delivered =
      Repo.all(
        from(r in DailyBriefRun,
          where:
            r.project_id == ^settings.project_id and r.kind == "personal_brief" and
              r.status == "completed" and r.created_at >= ^from_at,
          group_by: r.member_id,
          select: {r.member_id, max(r.created_at)}
        )
      )
      |> Map.new()

    Repo.all(
      from(m in DailyBriefMember,
        where: m.org_id == ^settings.org_id,
        select: {m.id, m.brief_requested_at}
      )
    )
    |> Map.new(fn {id, requested_at} ->
      {id,
       %{
         "last_brief_at" => Map.get(delivered, id),
         "requested_at" => requested_at
       }}
    end)
  end

  # A run's error may hold a provider's message; the page shows only its code.
  defp short(nil), do: nil

  defp short(error) do
    case Regex.run(~r/^(?:"?Slack API error: )?:?\{?:?([a-z_]{3,40})/, error) do
      [_, code] -> code
      nil -> "error"
    end
  end

  # The next workday time that is still ahead, as `Delivery` sends.
  defp next_at(settings, %{timezone: zone, deliver_at: at}, now) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} ->
        0..@calendar_lookahead_days
        |> Stream.map(&Date.add(DateTime.to_date(local), &1))
        |> Stream.filter(&Delivery.workday?(settings, &1))
        |> Stream.flat_map(fn day ->
          case DateTime.new(day, at, zone) do
            {:ok, time} -> [time]
            _gap -> []
          end
        end)
        |> Enum.find(&(DateTime.compare(&1, now) == :gt))
        |> then(&(&1 && DateTime.shift_zone!(&1, "Etc/UTC")))

      _invalid_zone ->
        nil
    end
  end

  defp min_at([]), do: nil
  defp min_at(times), do: Enum.min(times, DateTime)
end
