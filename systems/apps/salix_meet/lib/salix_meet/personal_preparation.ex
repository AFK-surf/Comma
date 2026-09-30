defmodule SalixMeet.PersonalPreparation do
  @moduledoc "Private report state for the assigned meeting Worker and fixed Slack recipients."

  alias SalixMeet.MeetingPlan
  alias SalixMeet.Ports.PersonalPreparation, as: Provider
  alias SalixStore.Ids
  alias SalixStore.MeetingPersonalPreparation, as: Store

  @batch_size 20
  @max_report_bytes 4_000

  def context(plan, opts \\ [])

  def context(%{"personal_preparation" => false} = plan, opts) do
    with :ok <- writable(plan, opts) do
      {:ok,
       %{
         "recipients" => [],
         "next_cursor" => nil,
         "total_attendees" => 0,
         "instructions" =>
           "Personal reminders are disabled for this meeting. Complete the shared report only."
       }}
    end
  end

  def context(plan, opts) do
    cursor = Keyword.get(opts, :cursor, 0)

    with true <- is_integer(cursor) and cursor >= 0 and cursor <= 2_147_483_647,
         :ok <- writable(plan, opts),
         {:ok, page, record} <- discover_page(plan, cursor) do
      {:ok,
       %{
         "connect_id" => connect_id(plan),
         "recipients" => record["recipients"],
         "next_cursor" => page["next_cursor"],
         "total_attendees" => page["total_attendees"],
         "publish_deadline_at" => get_in(plan, ["preparation", "publish_deadline_at"]),
         "instructions" =>
           "This private index is navigation. For each user_id, call read_recipient, then prepare " <>
             "and save that person before reading the next. Cite read_recipient for identity. " <>
             "Find supported follow-ups and relevant new progress for this person and meeting. " <>
             "Use only read_shared_source public originals. Submit preparation through publish_personal_report " <>
             "with this fixed connect_id, user_id and explicit ifc.sources original references. Never copy personal content " <>
             "into the shared report or Task checkpoints. Submit an empty draft with the read originals " <>
             "when no personal action is supported; the basic meeting reminder still goes out. " <>
             "Do not invent deadlines or new work in ten minutes. If next_cursor is non-null, call " <>
             "personal_context with that cursor, even after an empty recipient page. Drain all pages."
       }}
    else
      false -> {:error, :invalid_personal_preparation_page}
      {:error, _} = error -> error
    end
  end

  # Publication owns reminder discovery too, so it cannot depend on a Worker
  # starting or finishing before the reminder deadline.
  def prepare_reminders(plan) do
    discovery =
      with {:ok, cursor} <- Store.discovery_cursor(identity(plan)),
           do: discover_reminders(plan, cursor)

    # A later page must not prevent already discovered attendees from being
    # admitted. Preserve the discovery error so the schedule retries that page.
    with :ok <- Store.admit_reminders(identity(plan)), do: discovery
  end

  defp discover_reminders(_plan, nil), do: {:ok, false}

  defp discover_reminders(plan, cursor) do
    with {:ok, page, _record} <- discover_page(plan, cursor),
         do: {:ok, not is_nil(page["next_cursor"])}
  end

  defp discover_page(plan, cursor) do
    with {:ok, page} <- roster_page(plan, cursor),
         {:ok, recipients} <- Provider.recipients(plan, page["emails"]),
         true <- is_list(recipients) and length(recipients) <= @batch_size,
         {:ok, record} <- Store.ensure(identity(plan), recipients, cursor) do
      {:ok, page, record}
    else
      false -> {:error, :invalid_personal_preparation_page}
      {:error, _} = error -> error
    end
  end

  defp roster_page(plan, cursor) do
    with :ok <- ensure_roster(plan),
         {:ok, page} <- Store.roster_page(identity(plan), cursor) do
      if page["group_scan_pending"] do
        with {:ok, scan} <- Store.group_scan_page(identity(plan)),
             :ok <- expand_roster_page(plan, scan) do
          Store.roster_page(identity(plan), cursor)
        end
      else
        {:ok, page}
      end
    end
  end

  defp ensure_roster(plan) do
    case Store.roster_page(identity(plan), 0) do
      {:error, :not_found} ->
        with {:ok, emails} <- Provider.roster(plan),
             do: Store.ensure_roster(identity(plan), emails)

      {:ok, _} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp expand_roster_page(_plan, :complete), do: :ok

  defp expand_roster_page(plan, scan) do
    with {:ok, members} <- Provider.expand_groups(plan, scan["emails"]),
         do:
           Store.append_group_members(
             identity(plan),
             scan["cursor"],
             scan["next_cursor"],
             members
           )
  end

  def read_recipient(plan, user_id, opts \\ []) do
    with :ok <- writable(plan, opts),
         {:ok, recipient} <- Store.get_recipient(identity(plan), user_id) do
      {:ok,
       %{
         "connect_id" => connect_id(plan),
         "recipient" => Map.take(recipient, ~w(user_id email name)),
         "source_label" =>
           SalixIFC.Codec.encode_label(
             SalixIFC.Label.new([{:scope, connect_id(plan), "@" <> recipient["user_id"]}])
           )
       }}
    else
      {:error, :not_found} -> {:error, :meeting_personal_recipient_not_authorized}
      {:error, _} = error -> error
    end
  end

  def submit(plan, connect_id, user_id, text, evidence, opts \\ []) do
    with :ok <- writable(plan, opts),
         true <- connect_id == connect_id(plan),
         true <-
           is_nil(text) or
             (is_binary(text) and byte_size(text) <= @max_report_bytes and String.trim(text) != ""),
         {:ok, labels} <- source_labels(evidence),
         {:ok, recipient} <- Store.get_recipient(identity(plan), user_id),
         :ok <- Provider.authorize_report(plan, recipient, labels),
         :ok <-
           SalixMeet.PreparationSources.authorize_files(
             plan,
             Map.get(evidence, "source_files", [])
           ),
         {:ok, status} <-
           Store.save_report(identity(plan), user_id, %{
             "text" => if(is_binary(text), do: SalixMeet.PreparationMarkdown.normalize(text)),
             "sources_label" => labels,
             "source_files" => Map.get(evidence, "source_files", []),
             "source_evidence" => Map.take(evidence, ~w(decision requester)),
             "author" => Keyword.get(opts, :author),
             "status" => "prepared",
             "review_outcome" => if(is_nil(text), do: "no_supported_action", else: "ready")
           }) do
      if status == "skipped" do
        {:ok, %{"status" => "skipped", "user_id" => user_id, "reason" => "no_supported_action"}}
      else
        {:ok,
         %{
           "status" => "saved",
           "user_id" => user_id,
           "notice" => "scheduled_for_T_minus_#{plan["preparation_lead_minutes"] || 10}"
         }}
      end
    else
      false -> {:error, :invalid_personal_preparation_report}
      nil -> {:error, :meeting_personal_recipient_not_authorized}
      {:error, :not_found} -> {:error, :meeting_personal_recipient_not_authorized}
      {:error, _} = error -> error
      _ -> {:error, :meeting_personal_source_authorization_required}
    end
  end

  def pending(plan, opts \\ []),
    do: Store.pending(identity(plan), Keyword.get(opts, :now, System.system_time(:millisecond)))

  def has_pending?(%{"personal_preparation" => false}), do: {:ok, false}
  def has_pending?(plan), do: Store.has_pending?(identity(plan))

  def research_complete?(%{"personal_preparation" => false}), do: {:ok, true}
  def research_complete?(plan), do: Store.research_complete?(identity(plan))

  def settle(plan, user_id, status) when status in ~w(queued skipped),
    do: Store.settle(identity(plan), user_id, status)

  def defer(plan, user_id, retry_at, reason),
    do: Store.defer(identity(plan), user_id, retry_at, reason)

  def expire(plan), do: Store.expire(identity(plan))

  def enabled?(group_id, connect_id, user_id) do
    Store.enabled?(group_id, connect_id, user_id)
  end

  # Caller identity comes from the signed provider request, never tool arguments.
  def set_preference(group_id, origin, enabled) when is_map(origin) and is_boolean(enabled) do
    context = origin["provider_context"] || %{}
    connect_id = context["connect_id"]
    user_id = context["user_id"]

    if origin["provider"] == "slack" and origin["source_actor_type"] == "provider_user" and
         origin["agent_group_id"] == group_id and Ids.valid_group_id?(group_id) and
         is_binary(connect_id) and connect_id != "" and is_binary(user_id) and
         Regex.match?(~r/^[UW][A-Z0-9]+$/, user_id) do
      case Store.set_preference(group_id, connect_id, user_id, enabled) do
        :ok -> {:ok, %{"enabled" => enabled}}
        {:error, _} = error -> error
      end
    else
      {:error, :personal_preparation_requires_slack_request}
    end
  end

  def set_preference(_group_id, _origin, _enabled),
    do: {:error, :personal_preparation_requires_slack_request}

  defp source_labels(%{"sources_label" => labels, "declassified" => []})
       when is_list(labels) and length(labels) <= 32,
       do: {:ok, labels}

  defp source_labels(_), do: {:error, :meeting_personal_source_authorization_required}

  defp writable(plan, opts) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))
    deadline = get_in(plan, ["preparation", "publish_deadline_at"])

    with true <- get_in(plan, ["publication_target", "provider"]) == "slack",
         true <- plan["status"] == "planned" and is_integer(deadline) and now < deadline,
         :ok <- MeetingPlan.validate_report(plan) do
      :ok
    else
      false -> {:error, :meeting_personal_preparation_unavailable}
      {:error, _} = error -> error
    end
  end

  defp connect_id(plan), do: get_in(plan, ["publication_target", "params", "connect_id"])

  defp identity(plan),
    do: [
      plan["group_id"],
      plan["meeting_plan_id"],
      get_in(plan, ["preparation", "dispatch_revision"])
    ]
end
