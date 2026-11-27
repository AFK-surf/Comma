defmodule Comma.CollaborationGuests do
  @moduledoc """
  External email guest authentication and single-task access for Collaborative
  Tasks (`Comma.Collaborations`).

  An external guest invited by email receives a 7-day invite link (`/c/<token>`),
  verifies ownership of `invited_email` via a 6-digit OTP (`Comma.AuthChallenges`),
  and receives a single-task bearer session (`cgs_...`, stored only as SHA-256
  hash in `comma_collaboration_guest_sessions`).

  Privacy rule (4.2):
  - Only the host sees an external guest's full email.
  - Before OTP, the invite preview shows only a masked `email_hint`.
  - After OTP, `task.members` NEVER includes `email` or `email_hint` on any
    member entry; an unnamed external guest has `name: nil`.
  - Guest messages NEVER fall back to `email` as display name (unnamed guests omit `author_name` so clients render localized Anonymous).
  """

  import Ecto.Query

  alias Comma.Accounts.User
  alias Comma.Data.{CollaborationGuestSession, TaskCollaborator}
  alias Comma.{AuthChallenges, Repo, Workspaces}

  @token_prefix "cgs_"
  @session_ttl_seconds 30 * 86_400
  @guest_name_max_bytes 80

  @doc "Masks an email address for pre-OTP invite preview (e.g. `a***@example.com`)."
  @spec email_hint(String.t() | nil) :: String.t()
  def email_hint(email) when is_binary(email) do
    case String.split(String.trim(email), "@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        first = String.first(local)
        masked_local = if String.length(local) <= 1, do: "*", else: first <> "***"
        masked_local <> "@" <> domain

      _ ->
        "***"
    end
  end

  def email_hint(_), do: "***"

  @doc "Public preview for `GET /v1/comma/public/collaborations/invites/:token`."
  def invite_preview(token) when is_binary(token) and token != "" do
    with {:ok, row, _workspace, task} <- load_live_invite(token) do
      host_name = host_display_name(row.host_user_id)

      {:ok,
       %{
         "invite" => %{
           "status" => row.status,
           "email_hint" => email_hint(row.invited_email),
           "expires_at" => iso8601(row.invite_expires_at),
           "title" => task_title(row, task),
           "host_name" => host_name
         }
       }}
    end
  end

  def invite_preview(_token), do: {:error, :not_found}

  @doc "Requests a 6-digit OTP email for the invited external guest."
  def request_otp(token, params, request_attrs) when is_binary(token) and is_map(params) do
    with {:ok, row, _workspace, _task} <- load_live_invite(token),
         :ok <- check_email_match(params["email"], row.invited_email),
         {:ok, challenge} <-
           AuthChallenges.request_collaboration_guest_otp(
             row.invited_email,
             row.id,
             request_attrs
           ) do
      payload =
        %{
          "challenge_id" => challenge["challenge_id"],
          "expires_in_seconds" => challenge["expires_in"] || 900,
          "resend_after_seconds" => challenge["resend_after"] || 60,
          "email_hint" => email_hint(row.invited_email)
        }
        |> then(fn map ->
          if is_binary(challenge["code"]),
            do: Map.put(map, "debug_code", challenge["code"]),
            else: map
        end)

      {:ok, payload}
    end
  end

  def request_otp(_token, _params, _request_attrs), do: {:error, :not_found}

  @doc "Verifies the 6-digit OTP, activates the guest seat, and issues a `cgs_...` session."
  def verify_otp(token, params) when is_binary(token) and is_map(params) do
    with {:ok, row, _workspace, task} <- load_live_invite(token),
         {:ok, _challenge} <- AuthChallenges.verify_collaboration_guest_otp(row.id, params) do
      now = now()
      guest_name = normalize_guest_name(params["name"]) || nonblank(row.guest_name)
      decided_at = row.decided_at || now

      case from(c in TaskCollaborator,
             where: c.id == ^row.id and is_nil(c.user_id) and c.status in ["invited", "active"],
             select: c
           )
           |> Repo.update_all(
             set: [
               status: "active",
               decided_at: decided_at,
               guest_name: guest_name,
               updated_at: now
             ]
           ) do
        {1, [updated_row]} ->
          raw_token =
            @token_prefix <>
              Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

          expires_at = DateTime.add(now, @session_ttl_seconds, :second)

          %CollaborationGuestSession{
            id: new_id("cgs_"),
            collaborator_id: updated_row.id,
            workspace_id: updated_row.workspace_id,
            group_id: updated_row.group_id,
            conversation_id: updated_row.conversation_id,
            email: updated_row.invited_email,
            token_hash: hash_token(raw_token),
            expires_at: expires_at,
            last_used_at: now,
            inserted_at: now,
            updated_at: now
          }
          |> Repo.insert!()

          {:ok,
           %{
             "token" => raw_token,
             "expires_at" => DateTime.to_iso8601(expires_at),
             "guest" => %{
               "email" => updated_row.invited_email,
               "name" => nonblank(updated_row.guest_name)
             },
             "task" => %{
               "group_id" => updated_row.group_id,
               "conversation_id" => updated_row.conversation_id,
               "title" => task_title(updated_row, task),
               "status" => task["status"] || "active"
             }
           }}

        _ ->
          {:error, :invite_expired}
      end
    end
  end

  def verify_otp(_token, _params), do: {:error, :not_found}

  @doc """
  Authenticates a `cgs_...` guest token on EVERY request: verifies the session
  is unrevoked and unexpired, the collaborator row is still `active` (and
  unclaimed), and the host Workspace is ready.
  """
  def authenticate(raw_token) when is_binary(raw_token) do
    if String.starts_with?(raw_token, @token_prefix) do
      digest = hash_token(raw_token)
      current = now()

      case Repo.one(
             from(s in CollaborationGuestSession,
               join: c in TaskCollaborator,
               on: c.id == s.collaborator_id,
               where: s.token_hash == ^digest,
               select: {s, c}
             )
           ) do
        nil ->
          {:error, :unauthorized}

        {%CollaborationGuestSession{} = session, %TaskCollaborator{} = collaborator} ->
          cond do
            not is_nil(session.revoked_at) ->
              {:error, :guest_session_revoked}

            DateTime.compare(session.expires_at, current) != :gt ->
              {:error, :guest_session_revoked}

            collaborator.status != "active" or not is_nil(collaborator.user_id) ->
              {:error, :guest_session_revoked}

            true ->
              case Workspaces.collaboration_host(session.workspace_id) do
                {:ok, workspace} ->
                  scoped_workspace =
                    workspace
                    |> Map.put("default_group_id", session.group_id)
                    |> Map.put("home_group_id", workspace["default_group_id"])

                  case Comma.Salix.Client.impl().resolve_workspace_scope(scoped_workspace) do
                    {:ok, resolved} ->
                      {:ok,
                       %{
                         session: session,
                         collaborator: collaborator,
                         workspace: resolved
                       }}

                    {:error, _reason} ->
                      {:error, :guest_session_revoked}
                  end

                {:error, _reason} ->
                  {:error, :guest_session_revoked}
              end
          end
      end
    else
      {:error, :unauthorized}
    end
  end

  def authenticate(_token), do: {:error, :unauthorized}

  @doc "Revokes all active guest sessions for `collaborator_id` and notifies SSE streams."
  def revoke_sessions(collaborator_id) when is_binary(collaborator_id) do
    current = now()

    from(s in CollaborationGuestSession,
      where: s.collaborator_id == ^collaborator_id and is_nil(s.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: current, updated_at: current])

    broadcast_revoked(collaborator_id)
    :ok
  end

  def revoke_sessions(_), do: :ok

  @doc "Subscribes the calling process to revocation events for a guest collaborator."
  def subscribe(collaborator_id) when is_binary(collaborator_id) do
    Phoenix.PubSub.subscribe(pubsub(), topic(collaborator_id))
  end

  @doc "Guest leaves the Task: marks collaborator `left` and revokes all guest sessions."
  def leave(%{collaborator: %TaskCollaborator{} = row}) do
    current = now()

    case from(c in TaskCollaborator,
           where: c.id == ^row.id and c.status == "active" and is_nil(c.user_id),
           select: c
         )
         |> Repo.update_all(set: [status: "left", decided_at: current, updated_at: current]) do
      {1, [updated]} ->
        revoke_sessions(updated.id)
        {:ok, %{"id" => updated.id, "status" => updated.status}}

      _ ->
        {:error, :guest_session_revoked}
    end
  end

  @doc """
  Builds the privacy-safe member list for `GET /v1/comma/public/collaborations/task`:
  NEVER includes `email` or `email_hint` on any entry!
  """
  def task_members_for_guest(%TaskCollaborator{} = current) do
    rows =
      from(c in TaskCollaborator,
        where:
          c.workspace_id == ^current.workspace_id and
            c.conversation_id == ^current.conversation_id and
            c.status in ["invited", "active"],
        order_by: [asc: c.inserted_at, asc: c.id]
      )
      |> Repo.all()

    user_ids =
      [current.host_user_id | Enum.map(rows, & &1.user_id)]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    users =
      if user_ids == [] do
        %{}
      else
        from(u in User, where: u.id in ^user_ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
      end

    host_entry = %{
      "role" => "host",
      "name" => user_display_name(users[current.host_user_id]),
      "status" => "active",
      "is_guest" => false,
      "is_self" => false
    }

    member_entries =
      Enum.map(rows, fn
        %TaskCollaborator{user_id: nil} = guest_row ->
          %{
            "role" => "member",
            "name" => nonblank(guest_row.guest_name),
            "status" => guest_row.status,
            "is_guest" => true,
            "is_self" => guest_row.id == current.id
          }

        %TaskCollaborator{user_id: uid} = member_row ->
          %{
            "role" => "member",
            "name" => user_display_name(users[uid]),
            "status" => member_row.status,
            "is_guest" => false,
            "is_self" => false
          }
      end)

    [host_entry | member_entries]
  end

  @doc "Broadcasts `:guest_revoked` to any live SSE streams for `collaborator_id`."
  def broadcast_revoked(collaborator_id) when is_binary(collaborator_id),
    do: Phoenix.PubSub.broadcast(pubsub(), topic(collaborator_id), :guest_revoked)

  def broadcast_revoked(_), do: :ok

  @doc """
  Resolves privacy-safe display names for all participants of a Collaborative
  Task (host, registered members, and external guests) for projecting guest-facing
  messages. NEVER includes emails.
  """
  def message_sender_directory(%TaskCollaborator{} = current) do
    rows =
      from(c in TaskCollaborator,
        where:
          c.workspace_id == ^current.workspace_id and
            c.conversation_id == ^current.conversation_id
      )
      |> Repo.all()

    user_ids =
      [current.host_user_id | Enum.map(rows, & &1.user_id)]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    users =
      if user_ids == [] do
        %{}
      else
        from(u in User, where: u.id in ^user_ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
      end

    user_entries =
      Map.new(user_ids, fn uid ->
        fallback = if uid == current.host_user_id, do: "Host", else: "Member"
        name = user_display_name(users[uid], fallback)
        {uid, %{name: name, is_guest: false}}
      end)

    guest_entries =
      rows
      |> Enum.map(fn row ->
        name =
          if is_binary(row.user_id) do
            user_display_name(users[row.user_id], "Member")
          else
            nonblank(row.guest_name)
          end

        {"guest:" <> row.id, %{name: name, is_guest: true}}
      end)
      |> Map.new()

    Map.merge(user_entries, guest_entries)
  end

  @doc "Display name for a guest sender in messages, or nil when unnamed (NEVER falls back to email)."
  def sender_display_name(%TaskCollaborator{guest_name: name}) do
    nonblank(name)
  end

  @doc "Display name of the host user (never leaks raw email if name is set)."
  def host_display_name(host_user_id) when is_binary(host_user_id) do
    case Repo.get(User, host_user_id) do
      %User{} = user -> user_display_name(user)
      _ -> "Host"
    end
  end

  def host_display_name(_), do: "Host"

  ## Internal

  defp load_live_invite(token) do
    case Repo.get_by(TaskCollaborator, invite_token: token) do
      nil ->
        {:error, :not_found}

      %TaskCollaborator{} = row ->
        cond do
          not is_nil(row.user_id) ->
            {:error, :invite_expired}

          row.status not in ["invited", "active"] ->
            {:error, :invite_expired}

          expired?(row.invite_expires_at) ->
            {:error, :invite_expired}

          true ->
            with {:ok, workspace} <- Workspaces.collaboration_host(row.workspace_id),
                 scoped =
                   workspace
                   |> Map.put("default_group_id", row.group_id)
                   |> Map.put("home_group_id", workspace["default_group_id"]),
                 {:ok, resolved} <- Comma.Salix.Client.impl().resolve_workspace_scope(scoped),
                 {:ok, task} <-
                   Comma.Salix.Client.impl().get_group_conversation(resolved, row.conversation_id),
                 false <- task["status"] in ["archived", "deleted"] do
              {:ok, row, resolved, task}
            else
              _ -> {:error, :invite_expired}
            end
        end
    end
  end

  defp expired?(%DateTime{} = expires_at), do: DateTime.compare(expires_at, now()) != :gt
  defp expired?(_), do: false

  defp check_email_match(nil, _expected), do: :ok
  defp check_email_match("", _expected), do: :ok

  defp check_email_match(provided, expected) when is_binary(provided) and is_binary(expected) do
    if String.downcase(String.trim(provided)) == String.downcase(String.trim(expected)) do
      :ok
    else
      {:error, :email_mismatch}
    end
  end

  defp check_email_match(_provided, _expected), do: {:error, :email_mismatch}

  defp normalize_guest_name(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      byte_size(trimmed) > @guest_name_max_bytes -> String.slice(trimmed, 0, 40) |> String.trim()
      true -> trimmed
    end
  end

  defp normalize_guest_name(_), do: nil

  defp user_display_name(user, fallback \\ "Member")

  defp user_display_name(%User{name: name}, fallback) when is_binary(name) do
    case String.trim(name) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp user_display_name(_user, fallback), do: fallback

  defp task_title(%TaskCollaborator{title: title}, _task)
       when is_binary(title) and title != "",
       do: title

  defp task_title(_row, %{"title" => title}) when is_binary(title) and title != "", do: title
  defp task_title(_row, _task), do: "Shared Task"

  defp hash_token(raw_token),
    do: :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)

  defp topic(collaborator_id), do: "collaboration_guest:" <> collaborator_id
  defp pubsub, do: SystemsRuntime.get_env(:comma_core, :pubsub_server, CommaWeb.PubSub)

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank(_), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_), do: nil

  defp new_id(prefix),
    do: prefix <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

  defp now, do: SystemsClock.utc_now()
end
