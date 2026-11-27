defmodule SalixIM.Triage.StillfailCoordination do
  @moduledoc """
  Verified coordination between CFT Triage investigations and connected
  `still.fail` station sessions (`SalixStore.StationTaskIndex`).

   Evaluates whether a connected `still.fail` session is already working the
  same Slack thread (`SLACK/<channel>/<thread_ts>` or `<channel>/<thread_ts>`)
  or shares a strong PR/issue/Slack anchor with the Triage evaluation, and
  computes the verified disposition via `SalixVerifiedKernel.Proactive`:
  - `:defer_silence_already_handled` when an active `in_progress` `still.fail`
    session is already working the exact same Slack thread and no separate status
    check was asked;
  - `:surface_blocker_with_follow_up` when an overlapping `still.fail` session is
    stopped in `need` or `failed` while the Slack request seeks status or help,
    clamping any `follow_up` `recheck_after_hours` into `1..720`;
  - `:verify_public_evidence` or `:no_overlap` otherwise.
  """

  alias SalixVerifiedKernel.Proactive

  @github_url_re ~r<github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(?:pull|issues)/(\d+)>i
  @slack_archive_re ~r<slack\.com/archives/([A-Z0-9]+)/p(\d{10})(\d{6})>i

  @doc """
  Evaluates a list of `StationTaskIndex` rows (or `station_task.list` task maps)
  against a Triage `target` (`channel_id`, `thread_ts`) and Slack text excerpts.
  """
  @spec evaluate([map()], map(), [String.t()], boolean()) :: %{
          disposition:
            :no_overlap
            | :defer_silence_already_handled
            | :surface_blocker_with_follow_up
            | :verify_public_evidence,
          matched_task_id: String.t() | nil,
          card_kind: String.t() | nil,
          recommended_recheck_hours: pos_integer() | nil
        }
  def evaluate(station_rows, target, source_texts \\ [], asks_status_or_help? \\ false)
      when is_list(station_rows) and is_map(target) and is_list(source_texts) and
             is_boolean(asks_status_or_help?) do
    source_anchors = extract_anchors([slack_target_anchor(target) | source_texts])

    station_rows
    |> Enum.map(&score_row(&1, target, source_anchors, asks_status_or_help?))
    |> Enum.reject(&(&1.disposition == :no_overlap))
    |> Enum.sort_by(&priority/1)
    |> List.first(default_result())
  end

  @doc "Clamps a proposed Triage `follow_up` recheck interval into `1..720` hours."
  @spec clamp_recheck_hours(integer()) :: 1..720
  def clamp_recheck_hours(hours) when is_integer(hours),
    do: Proactive.clamp_follow_up_hours(hours)

  @doc "Extracts canonical strong resource anchors (`github:owner/repo#n`, `slack:ch/ts`) from texts."
  @spec extract_anchors([String.t() | nil]) :: [String.t()]
  def extract_anchors(texts) when is_list(texts) do
    texts
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn text ->
      gh =
        Regex.scan(@github_url_re, text, capture: :all_but_first)
        |> Enum.map(fn [repo, num] -> "github:#{String.downcase(repo)}##{num}" end)

      sl =
        Regex.scan(@slack_archive_re, text, capture: :all_but_first)
        |> Enum.map(fn [chan, sec, us] -> "slack:#{chan}/#{sec}.#{us}" end)

      gh ++ sl
    end)
    |> Enum.uniq()
  end

  defp score_row(row, target, source_anchors, asks_status_or_help?) when is_map(row) do
    same_thread? = same_slack_thread?(row, target)

    row_anchors =
      extract_anchors([
        field(row, :title),
        field(row, :note),
        field(row, :url),
        row_thread_slack_anchor(row)
      ])

    shared_anchor? =
      not same_thread? and Enum.any?(row_anchors, &(&1 in source_anchors))

    phase = stop_phase(row)
    card = card_kind(row)

    disposition =
      Proactive.triage_stillfail_guidance(
        same_thread?,
        shared_anchor?,
        asks_status_or_help?,
        phase
      )

    recheck_hours =
      if disposition == :surface_blocker_with_follow_up do
        Proactive.clamp_follow_up_hours(default_recheck_hours(phase, card))
      end

    %{
      disposition: disposition,
      matched_task_id: task_id(row),
      card_kind: card,
      recommended_recheck_hours: recheck_hours
    }
  end

  defp default_recheck_hours({:need, card}, _raw)
       when card in ["login", "secret", "signin", "device", "rig"],
       do: 1

  defp default_recheck_hours(:failed, _raw), do: 1
  defp default_recheck_hours(_phase, _raw), do: 4

  defp priority(%{disposition: :defer_silence_already_handled}), do: 0
  defp priority(%{disposition: :surface_blocker_with_follow_up}), do: 1
  defp priority(%{disposition: :verify_public_evidence}), do: 2
  defp priority(_), do: 3

  defp default_result do
    %{
      disposition: :no_overlap,
      matched_task_id: nil,
      card_kind: nil,
      recommended_recheck_hours: nil
    }
  end

  defp same_slack_thread?(row, target) do
    channel_id = target["channel_id"] || target[:channel_id]
    thread_ts = target["thread_ts"] || target[:thread_ts]
    thread = field(row, :thread) || thread_from_task_id(field(row, :task_id))

    is_binary(channel_id) and channel_id != "" and is_binary(thread_ts) and thread_ts != "" and
      (thread in [
         "#{channel_id}/#{thread_ts}",
         "SLACK/#{channel_id}/#{thread_ts}"
       ] or
         (is_binary(thread) and String.ends_with?(thread, "/#{channel_id}/#{thread_ts}")))
  end

  defp slack_target_anchor(target) do
    channel_id = target["channel_id"] || target[:channel_id]
    thread_ts = target["thread_ts"] || target[:thread_ts]

    if is_binary(channel_id) and is_binary(thread_ts) and String.contains?(thread_ts, ".") do
      [sec, us] = String.split(thread_ts, ".", parts: 2)
      "https://slack.com/archives/#{channel_id}/p#{sec}#{String.pad_trailing(us, 6, "0")}"
    end
  end

  defp row_thread_slack_anchor(row) do
    thread = field(row, :thread) || thread_from_task_id(field(row, :task_id))

    case is_binary(thread) && Regex.run(~r<(?:^|/)([CGD][A-Z0-9]+)/(\d{10})\.(\d{6})$>, thread) do
      [_, chan, sec, us] -> "https://slack.com/archives/#{chan}/p#{sec}#{us}"
      _ -> nil
    end
  end

  defp thread_from_task_id("station:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [_station_id, thread] -> thread
      _ -> nil
    end
  end

  defp thread_from_task_id(_), do: nil

  defp task_id(row) do
    field(row, :task_id) ||
      case {field(row, :station_id), field(row, :thread)} do
        {s, t} when is_binary(s) and is_binary(t) -> "station:#{s}:#{t}"
        _ -> nil
      end
  end

  defp stop_phase(row) do
    attention = field(row, :attention)
    status = field(row, :status)
    card = card_kind(row)

    cond do
      status in ["cancelled", "archived"] -> :done
      attention == "failed" -> :failed
      attention == "need" or status == "needs_review" -> if(card, do: {:need, card}, else: :need)
      attention == "done" or status == "done" -> :done
      true -> :working
    end
  end

  defp card_kind(row) do
    field(row, :card_kind) ||
      Enum.find_value(List.wrap(field(row, :labels)), fn
        "card:" <> kind when kind != "" -> kind
        _ -> nil
      end)
  end

  defp field(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
