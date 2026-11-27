defmodule Comma.Collaborations do
  @moduledoc """
  Collaborative Tasks: a Task one person hosts in their Workspace and shares
  with people they work with.

  The host starts it with people of their People list (those they hold an
  active Task Request grant with, either way) and its first message. Salix
  makes the Task with a Worker of its own that reaches nothing of the host's
  Group (`Comma.Salix.Client.create_collaborative_task/2`), and each person is
  invited (`invited`). An invited person joins (`active`) or declines
  (`declined`). An active member reads and writes that one Task through
  `/v1/comma/collaborations/...`; no other Task, chat, file or setting of the
  host's Workspace. A member leaves (`left`), or the host removes them
  (`removed`), and their access ends at once.

  The members are fixed when the Task starts: no row is added afterwards, so
  no one reads what was written before they could be named. The host is
  never a row: owning the Workspace is the host's authority. The Task's
  usage is the host Workspace's.
  See `docs/architecture/DOMAIN_CONCEPTS.md` (Collaborative Task).
  """

  import Ecto.Query

  alias Comma.Data.{
    CollaborationInviteSend,
    TaskCollaborator,
    TaskRequestGrant,
    Workspace
  }

  alias Comma.{CollaborationGuests, Repo, Workspaces}

  @max_people 7
  @title_bytes 200
  @content_bytes 16_000
  @invite_ttl_seconds 7 * 86_400
  @max_daily_email_invites 20
  @daily_window_seconds 86_400
  @request_id_pattern ~r/\A[A-Za-z0-9_-]{1,128}\z/

  ## Host

  @doc """
  Start a Collaborative Task in the host's Workspace with `attrs["people"]`
  (user ids of their People) and its first message `attrs["content"]`. A
  start asked again with the same `client_request_id` answers the same Task.
  """
  def start(user, session, workspace_id, attrs) when is_map(attrs) do
    with {:ok, workspace} <- authorize_host(user, session, workspace_id),
         {:ok, emails} <- emails(attrs["emails"], user["email"]),
         {:ok, people} <- people(attrs["people"], user["id"], emails),
         emails = emails -- people_emails(people),
         :ok <- email_daily_quota(user["id"], length(emails)),
         {:ok, content} <- text(attrs["content"], @content_bytes, "content"),
         {:ok, request_id} <- request_id(attrs["client_request_id"]),
         :ok <- all_contacts(user["id"], people),
         title = title(attrs["title"], content),
         {:ok, task} <-
           Comma.Salix.Client.impl().create_collaborative_task(workspace, %{
             "title" => title,
             "content" => content,
             "client_request_id" => "comma-collaboration:" <> user["id"] <> ":" <> request_id,
             "owner_user_id" => workspace["owner_user_id"],
             "collaboration" => %{"host_user_id" => user["id"], "members" => people}
           }) do
      now = now()

      rows =
        for person <- people do
          %{
            id: new_id("tcb_"),
            workspace_id: workspace_id,
            group_id: task["group_id"],
            conversation_id: task["conversation_id"],
            title: title,
            host_user_id: user["id"],
            user_id: person,
            status: "invited",
            inserted_at: now,
            updated_at: now
          }
        end ++
          for email <- emails do
            # A seat for someone not yet on Comma: gets a 7-day direct guest link
            # and whoever signs in with this address also takes the seat (`claim/1`).
            %{
              id: new_id("tcb_"),
              workspace_id: workspace_id,
              group_id: task["group_id"],
              conversation_id: task["conversation_id"],
              title: title,
              host_user_id: user["id"],
              invited_email: email,
              invite_token: new_invite_token(),
              invite_expires_at: DateTime.add(now, @invite_ttl_seconds, :second),
              status: "invited",
              inserted_at: now,
              updated_at: now
            }
          end

      # A retried start finds the Task's rows and adds none: its members were
      # fixed when it started, and a retry naming others is refused.
      existing =
        from(c in TaskCollaborator,
          where: c.conversation_id == ^task["conversation_id"],
          select: {c.user_id, c.invited_email}
        )
        |> Repo.all()

      cond do
        existing == [] ->
          Repo.insert_all(TaskCollaborator, rows)

          email_sends =
            for row <- rows, is_nil(row[:user_id]) do
              %{
                id: new_id("cis_"),
                host_user_id: user["id"],
                collaborator_id: row.id,
                inserted_at: now
              }
            end

          if email_sends != [], do: Repo.insert_all(CollaborationInviteSend, email_sends)
          # Each person hears of it by email too, not only when they open Comma.
          Comma.Workers.CollaborationInvite.enqueue(Enum.map(rows, & &1.id))

        MapSet.new(existing, fn {id, email} -> email || id end) ==
            MapSet.new(people ++ emails) ->
          :ok

        true ->
          throw(:members_fixed)
      end

      Enum.each(people, &changed/1)
      {:ok, %{"task" => %{"id" => task["conversation_id"], "group_id" => task["group_id"]}}}
    else
      # The same start asked again with other people: Salix holds the first
      # Task under this request id, and its members were fixed then.
      {:error, {:conflict, _reason}} -> {:error, :conflict}
      other -> other
    end
  catch
    :members_fixed -> {:error, :conflict}
  end

  def start(_user, _session, _workspace_id, _attrs),
    do: {:error, {:bad_request, "invalid collaboration"}}

  @doc "The members of one of the host's Collaborative Tasks, as the host sees them."
  def members(user, session, workspace_id, conversation_id) do
    with {:ok, _workspace} <- authorize_host(user, session, workspace_id) do
      rows =
        from(c in TaskCollaborator,
          where: c.workspace_id == ^workspace_id and c.conversation_id == ^conversation_id,
          order_by: [asc: c.inserted_at, asc: c.id]
        )
        |> Repo.all()

      users = users(Enum.map(rows, & &1.user_id))
      {:ok, Enum.map(rows, &host_member_view(&1, users))}
    end
  end

  @doc "The host takes a member (or an invite not yet answered) out of the Task."
  def remove(user, session, workspace_id, conversation_id, member_user_id) do
    with {:ok, _workspace} <- authorize_host(user, session, workspace_id),
         %TaskCollaborator{} = row <-
           Repo.one(
             from(c in TaskCollaborator,
               where:
                 c.workspace_id == ^workspace_id and c.conversation_id == ^conversation_id and
                   (c.user_id == ^member_user_id or c.id == ^member_user_id or
                      (is_nil(c.user_id) and c.invited_email == ^member_user_id))
             )
           ) || {:error, :not_found},
         {:ok, _row} <- settle(row, ~w(invited active), "removed") do
      CollaborationGuests.revoke_sessions(row.id)
      :ok
    end
  end

  @doc """
  Host manually resends an invitation email for an unclaimed external email seat
  (`user_id: nil`, `status in ["invited", "active"]`): rotates `invite_token`,
  resets `invite_expires_at` to `now + 7 days`, counts toward the 20/24h host
  cap, and enqueues a fresh invitation email.
  """
  def resend_invite(user, session, workspace_id, conversation_id, member_id) do
    with {:ok, _workspace} <- authorize_host(user, session, workspace_id),
         %TaskCollaborator{user_id: nil, status: status} = row
         when status in ["invited", "active"] <-
           Repo.one(
             from(c in TaskCollaborator,
               where:
                 c.workspace_id == ^workspace_id and c.conversation_id == ^conversation_id and
                   is_nil(c.user_id) and
                   (c.id == ^member_id or c.invited_email == ^member_id)
             )
           ) || {:error, :not_found},
         :ok <- email_daily_quota(user["id"], 1) do
      now = now()
      new_token = new_invite_token()
      expires_at = DateTime.add(now, @invite_ttl_seconds, :second)

      case from(c in TaskCollaborator,
             where: c.id == ^row.id and is_nil(c.user_id) and c.status in ["invited", "active"]
           )
           |> Repo.update_all(
             set: [
               invite_token: new_token,
               invite_expires_at: expires_at,
               updated_at: now
             ]
           ) do
        {1, _} ->
          Repo.insert_all(CollaborationInviteSend, [
            %{
              id: new_id("cis_"),
              host_user_id: user["id"],
              collaborator_id: row.id,
              inserted_at: now
            }
          ])

          Comma.Workers.CollaborationInvite.enqueue_resend(row.id, new_token)

          {:ok,
           %{
             "id" => row.id,
             "invited_email" => row.invited_email,
             "status" => row.status,
             "invite_expires_at" => DateTime.to_iso8601(expires_at)
           }}

        _ ->
          {:error, :not_found}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  ## Members

  @doc "The person's invites and the Tasks they are a member of, newest first."
  def list(user, session) do
    with :ok <- full_session(session) do
      claim(user)
      {:ok, list_rows(user)}
    end
  end

  @doc """
  The avatar of a person in a Collaborative Task (its host or a member), at
  revision `avatar_id`, for the Task's host or an invited/active member:
  `{:ok, content_type, body}`.
  """
  def member_avatar(user, session, group_id, conversation_id, target_user_id, avatar_id) do
    with :ok <- full_session(session),
         true <- is_binary(group_id) and is_binary(conversation_id) and is_binary(target_user_id) do
      rows =
        from(c in TaskCollaborator,
          where: c.group_id == ^group_id and c.conversation_id == ^conversation_id,
          select: {c.host_user_id, c.user_id, c.status}
        )
        |> Repo.all()

      caller_allowed? =
        Enum.any?(rows, fn {host_id, member_id, status} ->
          host_id == user["id"] or (member_id == user["id"] and status in ["invited", "active"])
        end)

      target_in_task? =
        Enum.any?(rows, fn {host_id, member_id, _status} ->
          host_id == target_user_id or member_id == target_user_id
        end)

      if caller_allowed? and target_in_task?,
        do: Comma.ProfileAvatar.fetch(target_user_id, avatar_id),
        else: {:error, :not_found}
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  # The seats invited by the account's own (signed-in, so confirmed) address
  # become its own: their invites then show as any invite does. A seat for a
  # Task the account is already in stays unclaimed.
  defp claim(%{"id" => id, "email" => email}) when is_binary(id) and is_binary(email) do
    if Comma.GuestMode.guest_email?(email), do: :ok, else: claim(id, String.downcase(email))
  end

  defp claim(_user), do: :ok

  defp claim(id, email) do
    # Almost no one has a seat waiting by email: one read of the partial
    # index first, and the write only when there is one.
    waiting =
      Repo.exists?(
        from(c in TaskCollaborator, where: is_nil(c.user_id) and c.invited_email == ^email)
      )

    if waiting, do: take_seats(id, email), else: :ok
  end

  defp take_seats(id, email) do
    taken =
      from(c in TaskCollaborator, where: c.user_id == ^id, select: c.conversation_id)

    {_count, claimed_ids} =
      from(c in TaskCollaborator,
        where:
          is_nil(c.user_id) and c.invited_email == ^email and
            c.status in ["invited", "active"] and
            c.host_user_id != ^id and c.conversation_id not in subquery(taken),
        select: c.id
      )
      |> Repo.update_all(set: [user_id: id, updated_at: now()])

    Enum.each(claimed_ids, &CollaborationGuests.revoke_sessions/1)
    :ok
  end

  defp list_rows(user) do
    rows =
      from(c in TaskCollaborator,
        where: c.user_id == ^user["id"] and c.status in ["invited", "active"],
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: 100
      )
      |> Repo.all()

    list_view(rows)
  end

  defp list_view([]), do: []

  defp list_view(rows) do
    others =
      from(c in TaskCollaborator,
        where:
          c.conversation_id in ^Enum.map(rows, & &1.conversation_id) and
            c.status in ["invited", "active"]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.conversation_id)

    # Hosts and members, in one read.
    named =
      users(
        Enum.map(rows, & &1.host_user_id) ++
          Enum.flat_map(Map.values(others), fn list -> Enum.map(list, & &1.user_id) end)
      )

    Enum.map(rows, fn row ->
      %{
        "id" => row.id,
        "status" => row.status,
        "title" => row.title,
        "task" => %{
          "id" => row.conversation_id,
          "group_id" => row.group_id,
          "workspace_id" => row.workspace_id
        },
        "host" => person(named[row.host_user_id]),
        "members" =>
          others
          |> Map.get(row.conversation_id, [])
          |> Enum.map(&member_view(&1, named)),
        "invited_at" => unix(row.inserted_at)
      }
    end)
  end

  @doc "An invited person joins the Task."
  def accept(user, session, id), do: decide(user, session, id, ~w(invited), "active")

  @doc "An invited person declines: they never join this Task."
  def decline(user, session, id), do: decide(user, session, id, ~w(invited), "declined")

  @doc "A member leaves the Task: they read and write it no more."
  def leave(user, session, id), do: decide(user, session, id, ~w(active), "left")

  defp decide(user, session, id, from, to) do
    with :ok <- full_session(session),
         %TaskCollaborator{} = row <-
           (is_binary(id) && Repo.get_by(TaskCollaborator, id: id, user_id: user["id"])) ||
             {:error, :not_found},
         {:ok, row} <- settle(row, from, to) do
      {:ok, %{"id" => row.id, "status" => row.status}}
    end
  end

  @doc """
  The host Workspace of a Task `user` is an active member of, for the
  `/v1/comma/collaborations/...` routes: the only authority a member has. A
  restricted session (a Mini App's, a channel panel's) has none.
  Anything else, the host's other Tasks included, is `:not_found`.
  """
  def authorize_member(user, session, group_id, conversation_id)
      when is_binary(group_id) and is_binary(conversation_id) do
    with :ok <- full_session(session),
         %TaskCollaborator{status: "active", workspace_id: workspace_id} <-
           Repo.get_by(TaskCollaborator,
             group_id: group_id,
             conversation_id: conversation_id,
             user_id: user["id"]
           ),
         {:ok, workspace} <- Workspaces.collaboration_host(workspace_id) do
      {:ok,
       workspace
       |> Map.put("default_group_id", group_id)
       |> Map.put("home_group_id", workspace["default_group_id"])}
    else
      {:error, :forbidden} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def authorize_member(_user, _session, _group_id, _conversation_id), do: {:error, :not_found}

  @doc """
  The host Workspace of a Task together that `user` may reach the files of:
  its host (who owns the Group) or one of its active members.
  """
  def task_scope(user, session, group_id, conversation_id) do
    case authorize_member(user, session, group_id, conversation_id) do
      {:ok, workspace} ->
        {:ok, workspace}

      _not_member ->
        with :ok <- full_session(session),
             {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
             true <- hosted?(workspace["id"], conversation_id) do
          {:ok, workspace}
        else
          _ -> {:error, :not_found}
        end
    end
  end

  defp hosted?(workspace_id, conversation_id),
    do:
      Repo.exists?(
        from(c in TaskCollaborator,
          where: c.workspace_id == ^workspace_id and c.conversation_id == ^conversation_id
        )
      )

  ## Change notices

  @doc "Subscribe to changes of the person's invites and memberships."
  def subscribe(%{"id" => user_id}) when is_binary(user_id),
    do: Phoenix.PubSub.subscribe(pubsub(), topic(user_id))

  def subscribe(_user), do: {:error, :not_found}

  defp changed(nil), do: :ok

  defp changed(user_id),
    do: Phoenix.PubSub.broadcast(pubsub(), topic(user_id), :collaborations_changed)

  defp topic(user_id), do: "collaborations:" <> user_id
  defp pubsub, do: SystemsRuntime.get_env(:comma_core, :pubsub_server, CommaWeb.PubSub)

  ## Internal

  # A row moves forward once: two answers race for one change.
  defp settle(%TaskCollaborator{} = row, from, to) do
    now = now()

    case from(c in TaskCollaborator, where: c.id == ^row.id and c.status in ^from, select: c)
         |> Repo.update_all(set: [status: to, decided_at: now, updated_at: now]) do
      {1, [row]} ->
        changed(row.user_id)
        announce(row)
        {:ok, row}

      _ ->
        {:error, :conflict}
    end
  end

  # Who left or was taken out is said in the Task, for its people only (no
  # Agent reads a product event). The line is a courtesy: the membership has
  # already changed, so a failure to write it changes nothing.
  defp announce(%TaskCollaborator{user_id: nil}), do: :ok

  defp announce(%TaskCollaborator{status: status} = row) when status in ~w(left removed) do
    client = Comma.Salix.Client.impl()

    with true <-
           Code.ensure_loaded?(client) and function_exported?(client, :append_product_event, 5),
         {:ok, workspace} <- Workspaces.collaboration_host(row.workspace_id),
         scoped = Map.put(workspace, "default_group_id", row.group_id),
         {:ok, workspace} <- client.resolve_workspace_scope(scoped) do
      client.append_product_event(
        workspace,
        row.conversation_id,
        "collaboration.member_changed",
        %{"member" => %{"user_id" => row.user_id, "status" => status}},
        "collaboration:" <> row.id <> ":" <> status
      )
    end

    :ok
  end

  defp announce(_row), do: :ok

  defp authorize_host(user, session, workspace_id) do
    with :ok <- full_session(session),
         {:ok, %{"kind" => "standard"} = workspace} <-
           Workspaces.authorize(user, session, workspace_id),
         true <- workspace["owner_user_id"] == user["id"] do
      {:ok, workspace}
    else
      {:ok, _guest} -> {:error, :forbidden}
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp full_session(%{"restricted" => true}), do: {:error, :forbidden}
  defp full_session(_session), do: :ok

  defp people(people, host_id, emails) when is_list(people) do
    people = Enum.uniq(people)

    cond do
      people == [] and emails == [] ->
        {:error, {:bad_request, "people is required"}}

      length(people) + length(emails) > @max_people ->
        {:error, {:bad_request, "at most #{@max_people} people"}}

      Enum.any?(people, &(not is_binary(&1) or &1 == "" or &1 == host_id)) ->
        {:error, {:bad_request, "people are other people's user ids"}}

      true ->
        {:ok, people}
    end
  end

  defp people(nil, _host_id, [_ | _]), do: {:ok, []}
  defp people(_people, _host_id, _emails), do: {:error, {:bad_request, "people is required"}}

  # An address of someone already picked from People is that person's seat.
  defp people_emails([]), do: []

  defp people_emails(people),
    do:
      from(u in Comma.Accounts.User,
        where: u.id in ^people,
        select: fragment("lower(?)", u.email)
      )
      |> Repo.all()

  # Host daily invite email limit: at most 20 external email invites (initial +
  # resends) per 24-hour rolling window.
  defp email_daily_quota(_host_id, 0), do: :ok

  defp email_daily_quota(host_id, incoming_count) when incoming_count > 0 do
    current = now()
    cutoff = DateTime.add(current, -@daily_window_seconds, :second)

    {sent_count, oldest} =
      from(s in CollaborationInviteSend,
        where: s.host_user_id == ^host_id and s.inserted_at > ^cutoff,
        select: {count(s.id), min(s.inserted_at)}
      )
      |> Repo.one()

    if sent_count + incoming_count > @max_daily_email_invites do
      retry_after =
        case oldest do
          %DateTime{} ->
            max(
              DateTime.diff(
                DateTime.add(oldest, @daily_window_seconds, :second),
                current,
                :second
              ),
              1
            )

          _ ->
            @daily_window_seconds
        end

      {:error, {:rate_limited, :invite_daily_limit_reached, retry_after}}
    else
      :ok
    end
  end

  # People not yet on Comma, by the address they will sign in with: at most a
  # few, never the host's own.
  @max_emails 5
  @email ~r/^[^@\s]{1,64}@[^@\s]+\.[^@\s]+$/

  defp emails(nil, _host_email), do: {:ok, []}

  defp emails(emails, host_email) when is_list(emails) do
    emails =
      emails
      |> Enum.map(&(is_binary(&1) && &1 |> String.trim() |> String.downcase()))
      |> Enum.uniq()

    cond do
      length(emails) > @max_emails ->
        {:error, {:bad_request, "at most #{@max_emails} emails"}}

      Enum.any?(emails, &(not is_binary(&1) or byte_size(&1) > 254 or not (&1 =~ @email))) ->
        {:error, {:bad_request, "emails are addresses"}}

      is_binary(host_email) and String.downcase(host_email) in emails ->
        {:error, {:bad_request, "emails are other people's addresses"}}

      Enum.any?(emails, &Comma.GuestMode.guest_email?/1) ->
        {:error, {:bad_request, "emails are addresses"}}

      true ->
        {:ok, emails}
    end
  end

  defp emails(_emails, _host_email), do: {:error, {:bad_request, "emails are addresses"}}

  # Everyone named is in the host's People: they hold an active grant with the
  # host, in either direction. Who is not is refused without saying who.
  defp all_contacts(host_id, people) do
    owned =
      from(w in Workspace,
        where: w.owner_user_id in ^[host_id | people] and w.status != "deleted",
        select: {w.id, w.owner_user_id}
      )
      |> Repo.all()
      |> Map.new()

    linked =
      from(g in TaskRequestGrant,
        where:
          g.status == "active" and g.workspace_id in ^Map.keys(owned) and
            g.grantee_user_id in ^[host_id | people],
        select: {g.workspace_id, g.grantee_user_id}
      )
      |> Repo.all()
      |> Enum.flat_map(fn {workspace_id, grantee} ->
        owner = owned[workspace_id]

        cond do
          owner == host_id -> [grantee]
          grantee == host_id -> [owner]
          true -> []
        end
      end)
      |> MapSet.new()

    if Enum.all?(people, &MapSet.member?(linked, &1)),
      do: :ok,
      else: {:error, {:bad_request, "everyone must be among your People"}}
  end

  defp text(value, bytes, name) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, {:bad_request, "#{name} is required"}}
      byte_size(value) > bytes -> {:error, {:bad_request, "#{name} is too long"}}
      true -> {:ok, value}
    end
  end

  defp text(_value, _bytes, name), do: {:error, {:bad_request, "#{name} is required"}}

  defp request_id(value) when is_binary(value) do
    if Regex.match?(@request_id_pattern, value),
      do: {:ok, value},
      else: {:error, {:bad_request, "invalid client_request_id"}}
  end

  defp request_id(_value), do: {:error, {:bad_request, "client_request_id is required"}}

  # The given title, else the message's first line.
  defp title(title, content) do
    if(is_binary(title) and String.trim(title) != "", do: title, else: content)
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> truncate(@title_bytes)
  end

  defp truncate(value, bytes) when byte_size(value) <= bytes, do: value

  defp truncate(value, bytes),
    do: value |> String.slice(0, div(bytes, 4)) |> String.trim()

  # Members may not know each other: another member's name and avatar, never
  # their email. An unclaimed external guest exposes only their optional guest
  # display name, never their email.
  defp member_view(%TaskCollaborator{user_id: nil} = row, _users),
    do: %{
      "person" => nil,
      "guest_name" => nonblank(row.guest_name),
      "is_guest" => true,
      "status" => row.status
    }

  defp member_view(%TaskCollaborator{} = row, users),
    do: %{"person" => public_person(users[row.user_id]), "status" => row.status}

  # The host's own view also names a seat no account has taken yet, by the
  # address the host typed, plus its id and invite expiry for manual resend.
  defp host_member_view(%TaskCollaborator{user_id: nil} = row, _users),
    do: %{
      "id" => row.id,
      "person" => nil,
      "invited_email" => row.invited_email,
      "guest_name" => nonblank(row.guest_name),
      "invite_expires_at" => iso8601(row.invite_expires_at),
      "is_guest" => true,
      "status" => row.status
    }

  defp host_member_view(row, users), do: member_view(row, users)

  defp public_person(nil), do: nil

  defp public_person(user),
    do: %{"id" => user.id, "name" => user.name, "avatar_id" => user.avatar_id}

  defp users(ids) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if ids == [],
      do: %{},
      else:
        from(u in Comma.Accounts.User, where: u.id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
  end

  defp person(nil), do: nil

  defp person(user),
    do: %{
      "id" => user.id,
      "name" => user.name,
      "email" => user.email,
      "avatar_id" => user.avatar_id
    }

  defp new_id(prefix),
    do: prefix <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

  defp new_invite_token,
    do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank(_), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_), do: nil

  defp now, do: SystemsClock.utc_now()
  defp unix(%DateTime{} = value), do: DateTime.to_unix(value)
  defp unix(_value), do: nil
end
