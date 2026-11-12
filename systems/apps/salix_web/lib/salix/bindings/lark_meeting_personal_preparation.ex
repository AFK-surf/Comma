defmodule Salix.Bindings.LarkMeetingPersonalPreparation do
  @moduledoc """
  Personal meeting reports on a Feishu/Lark connect
  (`Salix.Bindings.MeetingPersonalPreparation` hands a Feishu/Lark plan here).

  The recipients are the meeting's own people as its calendar names them.
  A Feishu/Lark calendar names an internal user attendee who has not
  declined by open_id, with a name, so no directory lookup is made. A Google
  calendar names attendees by email: the directory gives each email's
  open_id (`contact/v3/users/batch_get_id`, scope
  `contact:user.id:readonly`), and an email it does not know gets no report.
  Without that scope nobody of a Google meeting gets one; the team notice
  still goes. A meeting on members' calendars goes to the first of its
  plan's recipients (the organizer, then the member whose calendar holds it)
  whom the directory knows. A group attendee is not expanded. A report goes
  to the person's private chat with the bot, addressed by open_id.
  """

  require Logger

  alias Salix.Bindings.MeetingCalendarPreparation
  alias SalixIM.ProviderConnects
  alias SalixMeet.{CalendarEnrollmentCache, PersonalPreparation}

  @batch_size 20
  @lookup_batch 50

  def provider?(plan), do: get_in(plan, ["publication_target", "provider"]) in ["feishu", "lark"]

  # A meeting on members' calendars is prepared once, by the unit that
  # claims it (`Salix.Bindings.MeetingCalendar`), for its current attendees.
  def roster(%{"personal_recipients" => candidates} = plan) when is_list(candidates) do
    with {:ok, _entry} <- enrollment(plan),
         {:ok, connect} <- connect(plan),
         emails = candidates |> Enum.map(&email/1) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
         {:ok, open_ids} <- lookup_open_ids(connect, emails) do
      {:ok, emails |> Enum.filter(&Map.has_key?(open_ids, &1)) |> Enum.take(1)}
    else
      {:error, :personal_preparation_not_enrolled} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  def roster(plan) do
    with {:ok, _entry} <- enrollment(plan),
         {:ok, attendees} <- MeetingCalendarPreparation.read_attendees(plan) do
      {:ok, attendees |> Enum.flat_map(&attendee_id/1) |> Enum.uniq()}
    else
      {:error, :personal_preparation_not_enrolled} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  # A Feishu/Lark attendee by open_id; a Google attendee who has not declined
  # and is no room, by email.
  defp attendee_id(%{"user_id" => "ou_" <> _ = open_id}), do: [open_id]

  defp attendee_id(%{"email" => email} = attendee) do
    if attendee["responseStatus"] != "declined" and attendee["resource"] != true,
      do: List.wrap(email(email)),
      else: []
  end

  defp attendee_id(_attendee), do: []

  def expand_groups(_plan, _ids), do: {:ok, []}

  def recipients(plan, ids) when is_list(ids) and length(ids) <= @batch_size do
    with {:ok, _entry} <- enrollment(plan),
         {:ok, names} <- attendee_names(plan),
         {:ok, people} <- people(plan, ids) do
      connect_id = get_in(plan, ["publication_target", "params", "connect_id"])

      people
      |> Enum.reduce_while({:ok, []}, fn {open_id, email}, {:ok, recipients} ->
        case PersonalPreparation.enabled?(plan["group_id"], connect_id, open_id) do
          {:ok, true} ->
            recipient =
              %{"user_id" => open_id, "name" => names[email || open_id] || email || open_id}
              |> then(&if(email, do: Map.put(&1, "email", email), else: &1))

            {:cont, {:ok, [recipient | recipients]}}

          {:ok, false} ->
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
  end

  # A recipient is still current while the meeting's attendee list names them.
  def current_recipients(plan, pending)
      when is_list(pending) and length(pending) <= @batch_size do
    with {:ok, current} <- roster(plan) do
      current = MapSet.new(current)

      recipients(
        plan,
        pending
        |> Enum.map(&(&1["email"] || &1["user_id"]))
        |> Enum.filter(&MapSet.member?(current, &1))
      )
    end
  end

  @doc """
  The open_id of each email the directory of `connect` knows, by lowercased
  email. Anything unreadable gives none.
  """
  def open_ids(connect, emails) do
    case lookup_open_ids(connect, emails) do
      {:ok, open_ids} -> open_ids
      {:error, _} -> %{}
    end
  end

  # Without the scope the directory answers no email: that is no recipient,
  # not a failure to retry.
  defp lookup_open_ids(_connect, []), do: {:ok, %{}}

  defp lookup_open_ids(connect, emails) do
    api =
      if connect["provider"] == "lark",
        do: SalixIM.Provider.Lark.API,
        else: SalixIM.Provider.Feishu.API

    emails
    |> Enum.chunk_every(@lookup_batch)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, found} ->
      case api.post(connect, "/contact/v3/users/batch_get_id?user_id_type=open_id", %{
             "emails" => batch
           }) do
        {:ok, data} ->
          found =
            for %{"email" => email, "user_id" => "ou_" <> _ = open_id} <-
                  List.wrap(data["user_list"]),
                into: found,
                do: {String.downcase(String.trim(email)), open_id}

          {:cont, {:ok, found}}

        {:error, reason} ->
          if permission_failure?(reason) do
            Logger.warning(
              "meeting personal reminders: the directory refused emails: #{inspect(reason)}"
            )

            {:halt, {:ok, found}}
          else
            {:halt, {:error, {:lark_directory, reason}}}
          end
      end
    end)
  end

  defp permission_failure?(reason) do
    reason = reason |> inspect() |> String.downcase()
    Enum.any?(["permission", "scope", "99991672", "99991679"], &String.contains?(reason, &1))
  end

  # open_id and email of each id: an open_id is itself, an email is looked up.
  defp people(plan, ids) do
    {open_ids, emails} =
      ids
      |> Enum.filter(&is_binary/1)
      |> Enum.split_with(&open_id?/1)

    emails = emails |> Enum.map(&email/1) |> Enum.reject(&is_nil/1)

    found =
      if emails == [] do
        {:ok, %{}}
      else
        with {:ok, connect} <- connect(plan), do: lookup_open_ids(connect, emails)
      end

    with {:ok, found} <- found do
      {:ok,
       Enum.map(open_ids, &{&1, nil}) ++
         Enum.flat_map(emails, &if(found[&1], do: [{found[&1], &1}], else: []))}
    end
  end

  defp connect(plan) do
    case ProviderConnects.get_active_connect_by_id(
           plan["group_id"],
           get_in(plan, ["publication_target", "params", "connect_id"]),
           get_in(plan, ["publication_target", "provider"])
         ) do
      {:ok, connect} -> {:ok, connect}
      {:error, _} -> {:error, :meeting_personal_connect_unavailable}
    end
  end

  defp email(value) when is_binary(value) do
    email = value |> String.trim() |> String.downcase()
    if String.contains?(email, "@"), do: email
  end

  defp email(_value), do: nil

  def open_dm(_plan, %{"user_id" => "ou_" <> _ = open_id}), do: {:ok, open_id}
  def open_dm(_plan, _recipient), do: {:error, :meeting_personal_dm_unavailable}

  defp attendee_names(plan) do
    with {:ok, attendees} <- MeetingCalendarPreparation.read_attendees(plan) do
      {:ok,
       Map.new(attendees, fn
         %{"email" => email} = attendee when is_binary(email) ->
           {email(email), attendee["displayName"]}

         attendee ->
           {attendee["user_id"], attendee["name"]}
       end)}
    end
  end

  defp enrollment(plan) do
    with true <- SalixMeet.MeetingPlan.system_track?(plan),
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

  defp open_id?(value), do: is_binary(value) and String.starts_with?(value, "ou_")
end
