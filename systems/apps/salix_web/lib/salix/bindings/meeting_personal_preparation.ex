defmodule Salix.Bindings.MeetingPersonalPreparation do
  @moduledoc "Current organization meeting attendees and source audiences for personal meeting reports."
  @behaviour SalixMeet.Ports.PersonalPreparation

  alias Salix.Bindings.{GoogleGroupAttendees, MeetingCalendarPreparation}
  alias SalixIM.Provider.Slack.API
  alias SalixIM.ProviderConnects
  alias SalixMeet.{CalendarEnrollmentCache, PersonalPreparation}
  alias SalixStore.MeetingPersonalPreparation, as: Store

  @batch_size 20

  @impl true
  def roster(plan) do
    with {:ok, _entry} <- enrollment(plan),
         {:ok, attendees} <- MeetingCalendarPreparation.read_attendees(plan),
         true <- is_list(attendees) do
      {:ok,
       attendees
       |> Enum.filter(fn attendee ->
         is_map(attendee) and attendee["responseStatus"] != "declined" and
           attendee["resource"] != true and is_binary(attendee["email"])
       end)
       |> Enum.map(&String.downcase(String.trim(&1["email"])))
       |> Enum.reject(&(&1 == ""))
       |> Enum.uniq()}
    else
      {:error, :personal_preparation_not_enrolled} -> {:ok, []}
      {:error, _} = error -> error
      _ -> {:error, :invalid_meeting_attendees}
    end
  end

  @impl true
  def expand_groups(plan, emails), do: GoogleGroupAttendees.expand(plan, emails)

  @impl true
  def current_recipients(plan, pending)
      when is_list(pending) and length(pending) <= @batch_size do
    with {:ok, emails} <- roster(plan),
         {:ok, sources} <- Store.group_sources(identity(plan), Enum.map(pending, & &1["email"])),
         {:ok, members} <- current_group_members(plan, pending, emails, sources) do
      current = MapSet.new(emails)

      requested =
        pending
        |> Enum.map(& &1["email"])
        |> Enum.filter(&(MapSet.member?(current, &1) or MapSet.member?(members, &1)))

      recipients(plan, requested)
    end
  end

  defp current_group_members(plan, pending, emails, sources) do
    current = MapSet.new(emails)

    pairs =
      for %{"email" => email} <- pending,
          not MapSet.member?(current, email),
          group_email <- Map.get(sources, email, []),
          MapSet.member?(current, group_email),
          uniq: true,
          do: {email, group_email}

    case pairs do
      [] -> {:ok, MapSet.new()}
      _ -> GoogleGroupAttendees.current_members(plan, pairs)
    end
  end

  @impl true
  def recipients(plan, current_emails)
      when is_list(current_emails) and length(current_emails) <= @batch_size do
    with {:ok, _entry} <- enrollment(plan),
         {:ok, connect} <- connect(plan) do
      token = API.installation(connect)

      current_emails
      |> Enum.reduce_while({:ok, []}, fn email, {:ok, recipients} ->
        case lookup(token, connect, email) do
          {:ok, recipient} ->
            case PersonalPreparation.enabled?(
                   plan["group_id"],
                   connect["connect_id"],
                   recipient["user_id"]
                 ) do
              {:ok, true} -> {:cont, {:ok, [recipient | recipients]}}
              {:ok, false} -> {:cont, {:ok, recipients}}
              {:error, _} = error -> {:halt, error}
            end

          {:error, :slack_attendee_not_found} ->
            {:cont, {:ok, recipients}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, recipients} -> {:ok, Enum.reverse(recipients)}
        error -> error
      end
    else
      {:error, :personal_preparation_not_enrolled} -> {:ok, []}
      {:error, _} = error -> error
    end
  rescue
    _error in ArgumentError -> {:error, :meeting_personal_recipient_unavailable}
  end

  @impl true
  def authorize_report(plan, recipient, labels) do
    case SalixMeet.PreparationSources.authorize_labels(plan, recipient["user_id"], labels) do
      :ok -> :ok
      {:error, _} -> {:error, :meeting_personal_source_not_visible}
    end
  end

  @impl true
  def open_dm(plan, recipient) do
    with {:ok, connect} <- connect(plan) do
      result =
        API.request_form(
          API.installation(connect),
          "conversations.open",
          [users: recipient["user_id"]],
          timeout_ms: 1_000,
          pool_retries: 0
        )

      case get_in(result, ["channel", "id"]) do
        id when is_binary(id) ->
          if Regex.match?(~r/^D[A-Z0-9]+$/, id),
            do: {:ok, id},
            else: {:error, :meeting_personal_dm_unavailable}

        _ ->
          {:error, :meeting_personal_dm_unavailable}
      end
    end
  rescue
    _error in [API.Error, ArgumentError] -> {:error, :meeting_personal_dm_unavailable}
  end

  defp enrollment(plan) do
    with %{"provider" => "slack"} <- plan["publication_target"],
         {:ok, entry} <- SalixMeet.CalendarConfiguration.enrollment(plan),
         true <- entry["personal_preparation"] != false,
         {:ok, %{group: group}} <- CalendarEnrollmentCache.load(entry),
         true <- group["group_id"] == plan["group_id"] do
      {:ok, entry}
    else
      {:error, :meeting_preparation_not_enrolled} -> {:error, :personal_preparation_not_enrolled}
      {:error, _} = error -> error
      _ -> {:error, :personal_preparation_not_enrolled}
    end
  end

  defp connect(plan),
    do:
      ProviderConnects.get_active_connect_by_id(
        plan["group_id"],
        get_in(plan, ["publication_target", "params", "connect_id"]),
        "slack"
      )

  defp identity(plan),
    do: [
      plan["group_id"],
      plan["meeting_plan_id"],
      get_in(plan, ["preparation", "dispatch_revision"])
    ]

  defp lookup(token, connect, email) do
    result =
      API.request_form(token, "users.lookupByEmail", [email: email],
        timeout_ms: 1_000,
        pool_retries: 0
      )

    user = result["user"] || %{}
    id = user["id"]

    if is_binary(id) and Regex.match?(~r/^[UW][A-Z0-9]+$/, id) and
         user["team_id"] == connect["workspace_id"] and
         String.downcase(String.trim(get_in(user, ["profile", "email"]) || "")) == email and
         not Enum.any?(
           ~w(deleted is_bot is_app_user is_restricted is_ultra_restricted),
           &(user[&1] == true)
         ) do
      {:ok,
       %{"user_id" => id, "email" => email, "name" => user["real_name"] || user["name"] || email}}
    else
      {:error, :slack_attendee_not_found}
    end
  rescue
    error in API.Error ->
      if error.message == "users_not_found",
        do: {:error, :slack_attendee_not_found},
        else: {:error, :slack_attendee_lookup_failed}

    _error in ArgumentError ->
      {:error, :slack_attendee_lookup_failed}
  end
end
