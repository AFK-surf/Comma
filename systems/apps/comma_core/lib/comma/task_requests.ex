defmodule Comma.TaskRequests do
  @moduledoc """
  Task Requests: one person asks another person's Workspace for a Task.

  A Task Request Grant is the receiving Workspace owner's permission for one
  person to send requests. The owner creates it as an invite; its token is the
  only authority until a signed-in person accepts it, and that person alone
  holds the grant from then on. The owner sets its mode (`review`: each request
  waits for the owner; `auto_accept`: a request becomes a Task at once), a
  daily limit and a pending limit, and can revoke it. Nobody can ask for a
  grant: without an active one a send is refused and the owner sees nothing.

  A Task Request runs nothing and costs nothing until it is accepted. The
  owner accepts it (and may edit its words, place and model), which creates an
  ordinary Task in the Workspace, or declines it. Only the owner's own session
  accepts: no Agent can. An `auto_accept` request becomes a Task only where the
  Workspace would run it inside Comma or on its Cloud VM; one that would run on
  the owner's own station waits for the owner like a `review` one. A pending
  request expires after seven days (`expired`, a projection, not a stored
  status). The sender sees each request's status and, once accepted, its
  Task's status and latest reply; never the rest of the Task.

  A person also sends requests to their own Workspace, from a chat app linked
  to their account (a Comma for Teams Router): owning it is the authority, so
  such a request names no grant and counts against the default limits. It
  waits for them, or becomes a Task at once when they set their own requests to
  accept automatically (`own_request_mode`, the same rule as an `auto_accept`
  grant). It is only incoming, never among their sent ones.
  See `docs/architecture/DOMAIN_CONCEPTS.md` (Task Request).
  """

  import Ecto.Query

  alias Comma.Data.{TaskRequest, TaskRequestGrant, Workspace}
  alias Comma.{Repo, Workspaces}

  @invite_ttl_seconds 7 * 24 * 3600
  @request_ttl_seconds 7 * 24 * 3600
  @token_bytes 32
  @token_pattern ~r/\A[A-Za-z0-9_-]{43}\z/
  @modes ~w(review auto_accept)
  @default_daily_limit 20
  @default_pending_limit 10
  @max_daily_limit 200
  @max_pending_limit 50
  # A Workspace lists at most this many grants; an owner revokes one to add more.
  @grant_limit 100
  @page_limit 50
  @title_bytes 200
  @content_bytes 16_000
  @reason_bytes 1_000

  ## Owner: grants

  @doc "The Workspace's invites that are still open and its active grants, newest first."
  def list_grants(user, session, workspace_id) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id) do
      now = now()

      grants =
        from(grant in TaskRequestGrant,
          where:
            grant.workspace_id == ^workspace["id"] and
              (grant.status == "active" or
                 (grant.status == "invited" and grant.invite_expires_at > ^now)),
          order_by: [desc: grant.inserted_at, desc: grant.id],
          limit: @grant_limit
        )
        |> Repo.all()

      users = users(Enum.map(grants, & &1.grantee_user_id))
      {:ok, Enum.map(grants, &owner_grant_view(&1, users))}
    end
  end

  @doc """
  Creates an invite. Its token is in the answer and in the owner's list until
  someone accepts it or it expires.
  """
  def create_invite(user, session, workspace_id, attrs) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id),
         {:ok, settings} <- settings(attrs, %{}),
         :ok <- below_grant_limit(workspace["id"]) do
      now = now()

      %TaskRequestGrant{
        id: new_id("trg_"),
        workspace_id: workspace["id"],
        created_by: user["id"],
        invite_token: new_token(),
        invite_expires_at: DateTime.add(now, @invite_ttl_seconds, :second),
        status: "invited",
        mode: settings.mode,
        daily_limit: settings.daily_limit,
        pending_limit: settings.pending_limit
      }
      |> Repo.insert()
      |> case do
        {:ok, grant} -> {:ok, owner_grant_view(grant, %{})}
        {:error, _changeset} -> {:error, :task_requests_unavailable}
      end
    end
  end

  @doc "Changes a grant's mode or limits."
  def update_grant(user, session, workspace_id, grant_id, attrs) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id),
         %TaskRequestGrant{status: status} = grant when status in ~w(invited active) <-
           get_grant(workspace["id"], grant_id),
         {:ok, settings} <-
           settings(attrs, %{
             mode: grant.mode,
             daily_limit: grant.daily_limit,
             pending_limit: grant.pending_limit
           }) do
      {:ok, grant} = grant |> Ecto.Changeset.change(Map.to_list(settings)) |> Repo.update()
      {:ok, owner_grant_view(grant, users([grant.grantee_user_id]))}
    else
      nil -> {:error, :not_found}
      %TaskRequestGrant{} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Revokes a grant or an open invite. Its pending requests are declined, so a
  revoked sender leaves nothing waiting.
  """
  def revoke_grant(user, session, workspace_id, grant_id) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id),
         %TaskRequestGrant{} = grant <- get_grant(workspace["id"], grant_id) do
      revoke!(grant)
      :ok
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp revoke!(%TaskRequestGrant{} = grant) do
    now = now()

    Repo.transaction(fn ->
      from(g in TaskRequestGrant, where: g.id == ^grant.id and g.status != "revoked")
      |> Repo.update_all(
        set: [status: "revoked", invite_token: nil, revoked_at: now, updated_at: now]
      )

      {_count, senders} =
        from(r in TaskRequest,
          where: r.grant_id == ^grant.id and r.status == "pending",
          select: r.sender_user_id
        )
        |> Repo.update_all(set: [status: "declined", decided_at: now, updated_at: now])

      senders
    end)
    |> tap(fn
      # Whoever had requests waiting sees them declined.
      {:ok, senders} -> senders |> Enum.uniq() |> Enum.each(&sent_changed/1)
      _error -> :ok
    end)
  end

  ## Owner: requests

  @doc """
  The Workspace's requests, newest first: `pending` (the default) lists those
  still waiting, `all` every request of the last page.
  """
  def list_incoming(user, session, workspace_id, opts \\ []) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id),
         {:ok, filter} <- incoming_filter(Keyword.get(opts, :status)) do
      now = now()

      query =
        from(request in TaskRequest,
          where: request.workspace_id == ^workspace["id"],
          order_by: [desc: request.inserted_at, desc: request.id],
          limit: @page_limit
        )

      query =
        if filter == :pending,
          do: from(r in query, where: r.status == "pending" and r.expires_at > ^now),
          else: query

      requests = Repo.all(query)
      users = users(Enum.map(requests, & &1.sender_user_id))
      {:ok, Enum.map(requests, &incoming_view(&1, users, now))}
    end
  end

  @doc """
  Accepts a pending request. By default (`to: "task"`) it creates its Task in
  the Workspace, with the request's words or the owner's edit of them
  (`title`, `content`) and an optional place (`runs_on`) and model (`model`),
  checked as any Task's are. With `to: "router"` the owner sends it to their
  Router's chat as their own Message, and the Router decides what to do.
  Accepting again answers the first acceptance.
  """
  def accept_request(user, session, workspace_id, request_id, attrs \\ %{}) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id),
         {:ok, edit} <- accept_edit(attrs),
         %TaskRequest{} = request <- get_incoming(workspace["id"], request_id) do
      users = users([request.sender_user_id])

      case request.status do
        # `accepted` is the decision; what it starts may have been cut short.
        # Making the Task and sending the Router Message are both idempotent
        # (`client_request_id`), so accepting again finishes what is left: a
        # Task acceptance until it has its Task, a Router one every time.
        "accepted" when request.accepted_as == "task" and is_nil(request.task_id) ->
          start_task(workspace, request, edit, users, :owner)

        "accepted" when request.accepted_as == "router" ->
          to_router(user, session, workspace, request, edit, users)

        "accepted" ->
          {:ok, incoming_view(request, users, now())}

        "pending" ->
          cond do
            expired?(request, now()) -> {:error, :task_request_expired}
            edit["to"] == "router" -> to_router(user, session, workspace, request, edit, users)
            true -> start_task(workspace, request, edit, users, :owner)
          end

        _other ->
          {:error, :task_request_closed}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The avatar of a request's sender at `avatar_id`, for the Workspace owner who
  received the request: `{:ok, content_type, body}`.
  """
  def sender_avatar(user, session, workspace_id, request_id, avatar_id) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id),
         %TaskRequest{} = request <- get_incoming(workspace["id"], request_id) do
      Comma.ProfileAvatar.fetch(request.sender_user_id, avatar_id)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Declines a pending request, with an optional reason the sender sees."
  def decline_request(user, session, workspace_id, request_id, attrs \\ %{}) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id),
         {:ok, reason} <- optional_text(attrs["reason"], @reason_bytes),
         %TaskRequest{} = request <- get_incoming(workspace["id"], request_id) do
      now = now()

      case close_pending(request, "declined", now, decline_reason: reason) do
        {1, _} ->
          users = users([request.sender_user_id])

          {:ok,
           incoming_view(
             %{request | status: "declined", decline_reason: reason, decided_at: now},
             users,
             now
           )}

        {0, _} ->
          {:error, :task_request_closed}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  ## Sender: invites

  @doc """
  Who an invite is from, for the person about to accept it. With `workspace_id`,
  `back` says what accepting there would give the inviter: that Workspace and
  the mode their requests would run in, or nil when they could not send back.
  """
  def invite_preview(user, session, token, attrs \\ %{}) do
    with :ok <- full_session(session),
         {:ok, own} <- reciprocal_workspace(user, session, attrs),
         {:ok, grant, workspace} <- open_invite(token) do
      inviter = workspace.owner_user_id
      owner = users([inviter])[inviter]
      own_invite? = inviter == user["id"]

      back =
        case !own_invite? && back_grant(own, inviter) do
          {_held_or_new, mode} -> %{"workspace" => Map.take(own, ~w(id name)), "mode" => mode}
          _nothing -> nil
        end

      {:ok,
       %{
         "workspace" => workspace_view(workspace, owner),
         "mode" => grant.mode,
         "own" => own_invite?,
         "back" => back,
         "expires_at" => unix(grant.invite_expires_at)
       }}
    end
  end

  @doc """
  Accepts an invite: its grant becomes the signed-in person's. A grant they
  already held for the Workspace is revoked first, so the newest settings win.
  The owner cannot accept their own invite.

  With `workspace_id`, a `standard` Workspace the person owns, accepting also
  lets the inviter send requests back to it: the person grants the inviter
  that Workspace in `review` mode with the default limits, unless the inviter
  already holds an active grant there (its settings stay) or the Workspace is
  at its grant limit. A Workspace they cannot grant from grants nothing; the
  answer's `reciprocal` says whether the inviter can send back. One invite so
  connects two people both ways; each owner revokes their own side alone.
  """
  def accept_invite(user, session, token, attrs \\ %{}) do
    with :ok <- full_session(session),
         {:ok, own} <- reciprocal_workspace(user, session, attrs),
         {:ok, grant, workspace} <- open_invite(token),
         false <- workspace.owner_user_id == user["id"] do
      now = now()

      Repo.transaction(fn ->
        from(g in TaskRequestGrant,
          where:
            g.workspace_id == ^workspace.id and g.grantee_user_id == ^user["id"] and
              g.status == "active"
        )
        |> Repo.all()
        |> Enum.each(&revoke!/1)

        from(g in TaskRequestGrant, where: g.id == ^grant.id and g.status == "invited")
        |> Repo.update_all(
          set: [
            status: "active",
            grantee_user_id: user["id"],
            invite_token: nil,
            accepted_at: now,
            updated_at: now
          ]
        )
        |> case do
          {1, _} -> grant_back!(own, user, workspace, now)
          {0, _} -> Repo.rollback(:not_found)
        end
      end)
      |> case do
        {:ok, back} ->
          # The inviter's clients read again: their invite is now a person,
          # and the person's Workspace may be among their targets.
          incoming_changed(workspace.id)
          sent_changed(workspace.owner_user_id)
          if back, do: incoming_changed(own["id"])

          grant = Repo.get!(TaskRequestGrant, grant.id)

          {:ok,
           target_view(grant, workspace, users([workspace.owner_user_id]), %{}, now)
           |> Map.put("reciprocal", back)}

        {:error, _reason} = error ->
          error
      end
    else
      true -> {:error, :own_workspace}
      {:error, _reason} = error -> error
    end
  end

  defp reciprocal_workspace(user, session, attrs) when is_map(attrs) do
    case attrs["workspace_id"] do
      nil ->
        {:ok, nil}

      # A Workspace the person cannot grant from (a guest's, one not ready)
      # leaves the invite one way (`reciprocal: false`).
      id when is_binary(id) ->
        case authorize_owner(user, session, id) do
          {:ok, workspace} -> {:ok, workspace}
          {:error, _reason} -> {:ok, nil}
        end

      _ ->
        {:error, {:bad_request, "workspace_id must be a string"}}
    end
  end

  defp reciprocal_workspace(_user, _session, _attrs), do: {:ok, nil}

  # What the inviter would have in the person's own Workspace: the grant they
  # hold there, a new one, or nothing.
  defp back_grant(nil, _inviter), do: nil

  defp back_grant(own, inviter) do
    held =
      Repo.one(
        from(g in TaskRequestGrant,
          where:
            g.workspace_id == ^own["id"] and g.grantee_user_id == ^inviter and
              g.status == "active",
          select: g.mode
        )
      )

    cond do
      held -> {:held, held}
      below_grant_limit(own["id"]) == :ok -> {:new, "review"}
      true -> nil
    end
  end

  # Answers whether the inviter can send to the person's own Workspace now.
  defp grant_back!(own, user, %Workspace{owner_user_id: inviter}, now) do
    case back_grant(own, inviter) do
      {:held, _mode} ->
        true

      {:new, mode} ->
        Repo.insert!(%TaskRequestGrant{
          id: new_id("trg_"),
          workspace_id: own["id"],
          created_by: user["id"],
          grantee_user_id: inviter,
          status: "active",
          mode: mode,
          daily_limit: @default_daily_limit,
          pending_limit: @default_pending_limit,
          accepted_at: now
        })

        true

      nil ->
        false
    end
  end

  ## Sender: requests

  @doc "The Workspaces the signed-in person may send requests to, with what they have left today."
  def list_targets(user, session) do
    with :ok <- full_session(session) do
      now = now()

      rows =
        from(grant in TaskRequestGrant,
          join: workspace in Workspace,
          on: workspace.id == grant.workspace_id,
          where:
            grant.grantee_user_id == ^user["id"] and grant.status == "active" and
              workspace.status == "active",
          order_by: [desc: grant.accepted_at, desc: grant.id],
          limit: @grant_limit,
          select: {grant, workspace}
        )
        |> Repo.all()

      owners = users(Enum.map(rows, fn {_grant, workspace} -> workspace.owner_user_id end))
      counts = usage(Enum.map(rows, fn {grant, _workspace} -> grant.id end), now)

      {:ok,
       Enum.map(rows, fn {grant, workspace} ->
         target_view(grant, workspace, owners, counts, now)
       end)}
    end
  end

  @doc "How the owner's own requests to their Workspace are taken: `%{\"mode\" => \"review\" | \"auto_accept\"}`."
  def own_mode(user, session, workspace_id) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id) do
      {:ok, %{"mode" => Repo.get!(Workspace, workspace["id"]).own_request_mode}}
    end
  end

  @doc "Sets how the owner's own requests to their Workspace are taken (`mode`)."
  def set_own_mode(user, session, workspace_id, attrs) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id),
         mode when mode in @modes <- (is_map(attrs) && attrs["mode"]) || nil do
      {1, _} =
        from(w in Workspace, where: w.id == ^workspace["id"])
        |> Repo.update_all(set: [own_request_mode: mode, updated_at: now()])

      {:ok, %{"mode" => mode}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:bad_request, "mode must be review or auto_accept"}}
    end
  end

  @doc "The person's own Workspaces, which they send requests to without a grant."
  def own_targets(user) do
    {:ok,
     from(workspace in Workspace,
       where:
         workspace.owner_user_id == ^user["id"] and workspace.kind == "standard" and
           workspace.status == "active",
       order_by: [asc: workspace.inserted_at, asc: workspace.id],
       limit: @grant_limit
     )
     |> Repo.all()
     |> Enum.map(&%{"workspace_id" => &1.id, "workspace" => &1.name})}
  end

  @doc """
  Sends a request to the person's own Workspace `workspace_id`, as
  `send_request/5` does through a grant; `client_request_id` makes a retry
  answer the first send. `opts[:source]` is the chat message it was asked in,
  as for `send_request/5`.
  """
  def send_own_request(user, workspace_id, attrs, opts \\ []) do
    with {:ok, content} <- required_text(attrs["content"], @content_bytes),
         {:ok, title} <- optional_text(attrs["title"], @title_bytes),
         {:ok, client_request_id} <- client_request_id(attrs["client_request_id"]) do
      case Repo.get_by(TaskRequest,
             sender_user_id: user["id"],
             client_request_id: client_request_id
           ) do
        %TaskRequest{} = sent ->
          {:ok, sent_view(sent, sent_workspaces([sent]), now(), %{})}

        nil ->
          create_own_request(
            user,
            workspace_id,
            client_request_id,
            title || title_of(content),
            content,
            opts[:source]
          )
      end
    end
  end

  defp create_own_request(user, workspace_id, client_request_id, title, content, source) do
    now = now()

    Repo.transaction(fn ->
      with %Workspace{status: "active", kind: "standard"} = workspace <-
             from(w in Workspace,
               where: w.id == ^to_string(workspace_id) and w.owner_user_id == ^user["id"],
               lock: "FOR UPDATE"
             )
             |> Repo.one(),
           :ok <- within_own_limits(workspace.id, user["id"], now) do
        request =
          Repo.insert!(%TaskRequest{
            id: new_id("trq_"),
            workspace_id: workspace.id,
            sender_user_id: user["id"],
            client_request_id: client_request_id,
            title: title,
            content: content,
            status: "pending",
            source: source,
            expires_at: DateTime.add(now, @request_ttl_seconds, :second)
          })

        {workspace, request}
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, {%Workspace{own_request_mode: "auto_accept"} = workspace, request}} ->
        request = auto_accept(workspace, request)
        if request.status == "pending", do: incoming_changed(workspace.id)
        {:ok, sent_view(request, %{workspace.id => workspace}, now(), %{})}

      {:ok, {workspace, request}} ->
        incoming_changed(workspace.id)
        {:ok, sent_view(request, %{workspace.id => workspace}, now, %{})}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Sends a request through the person's grant `grant_id`. `content` says what
  to do; `title` is optional; `client_request_id` makes a retry answer the
  first send. `sender_workspace_id` names the person's Workspace it was
  written in, whose Router is told how it went; Salix names that Group itself
  (`opts[:sender_group_id]`) for a request from the Router chat.
  `opts[:source]` is the chat message a Comma for Teams Router was asked in;
  that Router replies there with the result (`CommaWeb.TaskRequestReceipts`).
  """
  def send_request(user, session, grant_id, attrs, opts \\ []) do
    with :ok <- full_session(session),
         {:ok, content} <- required_text(attrs["content"], @content_bytes),
         {:ok, title} <- optional_text(attrs["title"], @title_bytes),
         {:ok, client_request_id} <- client_request_id(attrs["client_request_id"]),
         {:ok, sender_group_id} <-
           sender_group(user, session, attrs["sender_workspace_id"], opts) do
      case Repo.get_by(TaskRequest,
             sender_user_id: user["id"],
             client_request_id: client_request_id
           ) do
        %TaskRequest{} = sent ->
          {:ok, sent_view(sent, sent_workspaces([sent]), now(), %{})}

        nil ->
          create_request(
            user,
            grant_id,
            client_request_id,
            title || title_of(content),
            content,
            sender_group_id,
            opts[:source]
          )
      end
    end
  end

  # The sender's own Group a request was written in: a Workspace they own, or
  # the Group Salix names. None when neither is given.
  defp sender_group(user, session, workspace_id, opts) do
    case opts[:sender_group_id] do
      group when is_binary(group) -> {:ok, group}
      _none -> workspace_group(user, session, workspace_id)
    end
  end

  defp workspace_group(user, session, workspace_id)
       when is_binary(workspace_id) and workspace_id != "" do
    case Workspaces.authorize(user, session, workspace_id) do
      {:ok, workspace} -> {:ok, workspace["default_group_id"]}
      {:error, _reason} = error -> error
    end
  end

  defp workspace_group(_user, _session, _workspace_id), do: {:ok, nil}

  defp create_request(user, grant_id, client_request_id, title, content, sender_group_id, source) do
    now = now()

    Repo.transaction(fn ->
      with %TaskRequestGrant{} = grant <-
             from(g in TaskRequestGrant,
               where:
                 g.id == ^to_string(grant_id) and g.grantee_user_id == ^user["id"] and
                   g.status == "active",
               lock: "FOR UPDATE"
             )
             |> Repo.one(),
           %Workspace{status: "active"} = workspace <- Repo.get(Workspace, grant.workspace_id),
           :ok <- within_limits(grant, now) do
        request =
          Repo.insert!(%TaskRequest{
            id: new_id("trq_"),
            grant_id: grant.id,
            workspace_id: grant.workspace_id,
            sender_user_id: user["id"],
            client_request_id: client_request_id,
            title: title,
            content: content,
            status: "pending",
            sender_group_id: sender_group_id,
            source: source,
            expires_at: DateTime.add(now, @request_ttl_seconds, :second)
          })

        {grant, workspace, request}
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, {%TaskRequestGrant{mode: "auto_accept"}, workspace, request}} ->
        request = auto_accept(workspace, request)
        if request.status == "pending", do: incoming_changed(workspace.id)
        {:ok, sent_view(request, %{workspace.id => workspace}, now(), %{})}

      {:ok, {_grant, workspace, request}} ->
        incoming_changed(workspace.id)
        {:ok, sent_view(request, %{workspace.id => workspace}, now, %{})}

      {:error, _reason} = error ->
        error
    end
  end

  # An auto-accepted request becomes a Task only where the Workspace runs it
  # inside Comma or on its Cloud VM; otherwise, and when the Task cannot be
  # made now, it waits for the owner.
  defp auto_accept(workspace, request) do
    case Workspaces.get(workspace.id) do
      {:ok, view} ->
        case start_task(view, request, %{}, %{}, :auto) do
          {:ok, _accepted} -> Repo.get!(TaskRequest, request.id)
          {:error, _reason} -> request
        end

      {:error, _reason} ->
        request
    end
  end

  @doc "The person's sent requests, newest first, with each accepted one's Task status."
  def list_sent(user, session) do
    with :ok <- full_session(session) do
      requests =
        from(request in TaskRequest,
          where: request.sender_user_id == ^user["id"] and not is_nil(request.grant_id),
          order_by: [desc: request.inserted_at, desc: request.id],
          limit: @page_limit
        )
        |> Repo.all()

      workspaces = sent_workspaces(requests)
      now = now()

      {:ok,
       Enum.map(requests, fn request ->
         sent_view(request, workspaces, now, task_state(request))
       end)}
    end
  end

  @doc "One sent request, with its Task's status and latest reply once accepted."
  def get_sent(user, session, request_id) do
    with :ok <- full_session(session),
         %TaskRequest{} = request <-
           Repo.get_by(TaskRequest, id: to_string(request_id), sender_user_id: user["id"]) do
      workspaces = sent_workspaces([request])
      {:ok, sent_view(request, workspaces, now(), task_state(request))}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The avatar of the person a sent request went to (its Workspace's owner), at
  revision `avatar_id`, for the request's sender: `{:ok, content_type, body}`.
  """
  def recipient_avatar(user, session, request_id, avatar_id) do
    with :ok <- full_session(session),
         %TaskRequest{} = request <-
           Repo.get_by(TaskRequest, id: to_string(request_id), sender_user_id: user["id"]),
         %Workspace{owner_user_id: owner} <- Repo.get(Workspace, request.workspace_id) do
      Comma.ProfileAvatar.fetch(owner, avatar_id)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The avatar of a Workspace the person may send requests to (its owner), at
  revision `avatar_id`, through their active grant `grant_id`:
  `{:ok, content_type, body}`.
  """
  def target_avatar(user, session, grant_id, avatar_id) do
    with :ok <- full_session(session),
         %TaskRequestGrant{} = grant <-
           Repo.get_by(TaskRequestGrant,
             id: to_string(grant_id),
             grantee_user_id: user["id"],
             status: "active"
           ),
         %Workspace{owner_user_id: owner} <- Repo.get(Workspace, grant.workspace_id) do
      Comma.ProfileAvatar.fetch(owner, avatar_id)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Withdraws a pending request the person sent."
  def withdraw(user, session, request_id) do
    with :ok <- full_session(session),
         %TaskRequest{} = request <-
           Repo.get_by(TaskRequest, id: to_string(request_id), sender_user_id: user["id"]) do
      now = now()

      case close_pending(request, "withdrawn", now) do
        {1, _} ->
          incoming_changed(request.workspace_id)

          {:ok,
           sent_view(
             %{request | status: "withdrawn", decided_at: now},
             sent_workspaces([request]),
             now,
             %{}
           )}

        {0, _} ->
          {:error, :task_request_closed}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Sends the calling process `{:task_requests_changed, workspace_id}` each time
  a request to the Workspace comes or its sender withdraws it. The caller has
  already authorized the Workspace's owner (the Group's task list stream).
  """
  def subscribe_incoming(%{"id" => workspace_id}) when is_binary(workspace_id),
    do: Phoenix.PubSub.subscribe(pubsub(), incoming_topic(workspace_id))

  def subscribe_incoming(_workspace), do: {:error, :not_found}

  # The owner's clients read their requests again (their task stream says so).
  defp incoming_changed(workspace_id),
    do:
      Phoenix.PubSub.broadcast(
        pubsub(),
        incoming_topic(workspace_id),
        {:task_requests_changed, workspace_id}
      )

  defp incoming_topic(workspace_id), do: "task_requests:" <> workspace_id

  @doc """
  Sends the calling process `{:sent_task_requests_changed, user_id}` each
  time a request the person sent is decided or its Task reports a new status.
  The caller has already authorized the person (their task list stream).
  """
  def subscribe_sent(%{"id" => user_id}) when is_binary(user_id),
    do: Phoenix.PubSub.subscribe(pubsub(), sent_topic(user_id))

  def subscribe_sent(_user), do: {:error, :not_found}

  # The sender's clients read their sent requests again.
  defp sent_changed(user_id),
    do:
      Phoenix.PubSub.broadcast(
        pubsub(),
        sent_topic(user_id),
        {:sent_task_requests_changed, user_id}
      )

  defp sent_topic(user_id), do: "sent_task_requests:" <> user_id

  ## Receipts: what an accepted request's Task tells its sender

  # A Task in one of these has something for its sender to read: the words of
  # its latest Agent Message are kept with the request.
  @result_statuses ~w(ready_for_review escalated failed completed cancelled)

  @doc "The accepted request a Task was made from, if any (`group_id`, `task_id`)."
  def for_task(group_id, task_id) when is_binary(group_id) and is_binary(task_id),
    do: Repo.get_by(TaskRequest, group_id: group_id, task_id: task_id, status: "accepted")

  def for_task(_group_id, _task_id), do: nil

  @doc """
  Keeps the status of the request's Task (its Salix record). Tells the sender's
  clients when it changed. What the Task says stays with the owner's Router, which
  reports what the sender gets (`record_report/4`). `{:ok, request, previous_status}`.
  """
  def record_task(%TaskRequest{} = request, %{"status" => status}) when is_binary(status) do
    if status == request.task_status do
      {:ok, request, request.task_status}
    else
      now = now()

      {1, [updated]} =
        from(r in TaskRequest, where: r.id == ^request.id, select: r)
        |> Repo.update_all(set: [task_status: status, task_updated_at: now, updated_at: now])

      sent_changed(request.sender_user_id)
      {:ok, updated, request.task_status}
    end
  end

  @doc "The accepted request `id` of the Workspace whose Group `group_id` is."
  def accepted_in_group(id, group_id) do
    with %TaskRequest{status: "accepted"} = request <- Repo.get(TaskRequest, id),
         {:ok, %{"default_group_id" => ^group_id}} <- router_scope(request) do
      {:ok, request}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  What the owner's Router chose to send back for the request's finished Task, once:
  the first report is what the sender gets, and the same report again changes
  nothing. `{:ok, request, :new | :repeated}`; run it with what must follow a new
  one in one transaction. The caller has checked the Task is the request's.
  """
  def record_report(
        %TaskRequest{} = request,
        group_id,
        %{"conversation_id" => task, "status" => status},
        content
      ) do
    content = String.slice(content, 0, 4_000)

    cond do
      status not in @result_statuses ->
        {:error, :task_not_finished}

      true ->
        now = now()

        # The database decides which report is the first; another reads what won.
        from(r in TaskRequest, where: r.id == ^request.id and is_nil(r.reported_at), select: r)
        |> Repo.update_all(
          set: [
            group_id: group_id,
            task_id: task,
            task_status: status,
            task_reply: content,
            reported_at: now,
            task_updated_at: now,
            updated_at: now
          ]
        )
        |> case do
          {1, [updated]} ->
            sent_changed(request.sender_user_id)
            {:ok, updated, :new}

          {0, _} ->
            first = Repo.get!(TaskRequest, request.id)

            if first.task_reply == content and first.task_id == task,
              do: {:ok, first, :repeated},
              else: {:error, :already_reported}
        end
    end
  end

  @doc "Who sent the request, by name."
  def sent_by(%TaskRequest{sender_user_id: sender}), do: sender_name(user(sender))

  @doc "The words of the latest Agent Message of the request's Task, for its owner's Router."
  def latest_task_reply(%TaskRequest{} = request, task) do
    with {:ok, scope} <- router_scope(request) do
      latest_reply(scope, request.task_id, task)
    else
      _ -> nil
    end
  end

  @doc "The Router's scope of the Workspace a request was sent to."
  def router_scope(%TaskRequest{workspace_id: workspace_id}) do
    with %Workspace{status: "active"} = workspace <- Repo.get(Workspace, workspace_id),
         {:ok, view} <- Workspaces.get(workspace.id) do
      Comma.Salix.Client.impl().resolve_workspace_scope(view)
    else
      _ -> {:error, :not_found}
    end
  end

  defp record_current_task(workspace, %TaskRequest{task_id: task_id} = request)
       when is_binary(task_id) do
    client = Comma.Salix.Client.impl()

    with {:ok, scope} <- client.resolve_workspace_scope(workspace),
         {:ok, %{"kind" => "agent_task"} = task} <- client.get_group_conversation(scope, task_id) do
      record_task(request, task)
    end
  end

  defp record_current_task(_workspace, _request), do: :ok

  @doc "Whether a Task status gives the sender a result to read."
  def result_status?(status), do: status in @result_statuses

  @doc "Who received the request, as the sender knows them: the Workspace owner's name."
  def recipient_name(%TaskRequest{workspace_id: workspace_id}) do
    with %Workspace{owner_user_id: owner} <- Repo.get(Workspace, workspace_id),
         %{} = user <- users([owner])[owner] do
      sender_name(user)
    else
      _ -> nil
    end
  end

  defp pubsub, do: SystemsRuntime.get_env(:comma_core, :pubsub_server, CommaWeb.PubSub)

  @doc "Whether a string has the shape of an invite token. Grants nothing."
  def valid_token?(token) when is_binary(token), do: Regex.match?(@token_pattern, token)
  def valid_token?(_token), do: false

  ## Accepting

  # The owner's own Message in their Router chat, sent with the owner's
  # session as any Message they write there; a retry is the same Message. It
  # names the request, whose result the Router reports (`task_request.report`).
  defp to_router(user, session, workspace, request, edit, users) do
    sender = sender_name(users[request.sender_user_id] || user(request.sender_user_id))
    content = edit["content"] || request.content

    text =
      "Task request from #{sender || "another person"}" <>
        if(edit["title"], do: ": #{edit["title"]}", else: "") <>
        "\n\n" <>
        content <>
        "\n\nThe request_id is #{request.id}. Open a Task for this with task_request_id set to it. Nothing goes back to #{sender || "them"} unless you call task_request.report once it has finished, with what they should get; your replies here stay in this chat."

    decided(request, "router", fn ->
      with {:ok, scope} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
           # A Workspace whose owner has not opened Home yet has no Router chat.
           {:ok, _router} <- Comma.Salix.Client.impl().ensure_group_router_conversation(scope),
           {:ok, _conversation} <-
             Comma.Conversations.send_message(
               user,
               session,
               scope["default_group_id"],
               scope["router_conversation_id"],
               %{"content" => text, "client_request_id" => "comma-task-request:" <> request.id}
             ) do
        {:ok, incoming_view(Repo.get!(TaskRequest, request.id), users, now())}
      end
    end)
  end

  defp start_task(workspace, request, edit, users, by) do
    sender = users[request.sender_user_id] || user(request.sender_user_id)

    attrs =
      %{
        "title" => edit["title"] || request.title,
        "content" => edit["content"] || request.content,
        "client_request_id" => "comma-task-request:" <> request.id,
        "owner_user_id" => workspace["owner_user_id"],
        "task_request" => %{
          "id" => request.id,
          "sender_user_id" => request.sender_user_id,
          "sender_name" => sender_name(sender),
          # The Task shows the sender's avatar at this revision (`sender_avatar/5`).
          "sender_avatar_id" => sender && sender.avatar_id,
          "workspace_id" => request.workspace_id
        }
      }
      |> put_present("runs_on", edit["runs_on"])
      |> put_present("model", edit["model"])
      |> put_present("repo", edit["repo"])
      |> put_present("account_id", edit["account_id"])

    decided(request, "task", fn ->
      with {:ok, task} <-
             Comma.Salix.Client.impl().create_requested_task(workspace, attrs,
               stations: by == :owner
             ) do
        now = now()

        from(r in TaskRequest, where: r.id == ^request.id and r.status == "accepted")
        |> Repo.update_all(
          set: [group_id: task["group_id"], task_id: task["conversation_id"], updated_at: now]
        )

        # The status observer found no request for what the Task published
        # before it was named here: keep what the Task says now.
        _ = record_current_task(workspace, Repo.get!(TaskRequest, request.id))
        {:ok, incoming_view(Repo.get!(TaskRequest, request.id), users, now)}
      end
    end)
  end

  # Accepting, declining, withdrawing and revoking the grant race for one
  # decision: each moves the request out of `pending` only if it is still
  # there. Acceptance takes the decision before it starts anything, so a
  # request withdrawn first never runs, and one accepted first can no longer
  # be withdrawn. When what it starts fails, the request goes back to
  # `pending` for the owner to try again.
  defp decided(%TaskRequest{status: "accepted"}, _as, run), do: run.()

  defp decided(request, as, run) do
    now = now()

    case close_pending(request, "accepted", now, accepted_as: as) do
      {1, _} ->
        case run.() do
          {:ok, _view} = ok ->
            ok

          error ->
            undecide(request)
            error
        end

      {0, _} ->
        {:error, :task_request_closed}
    end
  end

  # What an acceptance started failed: the request waits for the owner again,
  # unless its grant was revoked meanwhile, which declines what waits.
  # The grant's row is locked as revoking it locks it, so a revocation either
  # sees the request back in `pending` and declines it, or is seen here.
  defp undecide(request) do
    Repo.transaction(fn ->
      status =
        if is_nil(request.grant_id) do
          # An owner's own request has no grant to revoke.
          "pending"
        else
          from(g in TaskRequestGrant, where: g.id == ^request.grant_id, lock: "FOR UPDATE")
          |> Repo.one()
          |> case do
            %TaskRequestGrant{status: "active"} -> "pending"
            _revoked -> "declined"
          end
        end

      now = now()

      from(r in TaskRequest,
        where: r.id == ^request.id and r.status == "accepted" and is_nil(r.task_id)
      )
      |> Repo.update_all(
        set: [
          status: status,
          accepted_as: nil,
          decided_at: if(status == "declined", do: now),
          updated_at: now
        ]
      )
    end)
    |> tap(fn
      # The acceptance its sender heard of is undone: they read it again.
      {:ok, {1, _}} -> sent_changed(request.sender_user_id)
      _ -> :ok
    end)
  end

  ## Reads and views

  # What the request's Task last told its sender (`record_task/2`): nothing
  # before it is accepted, or before the Task first reports.
  defp task_state(%TaskRequest{status: "accepted"} = request),
    do: %{"task_status" => request.task_status, "reply" => request.task_reply}

  defp task_state(_request), do: %{}

  # The words of the Task's last Agent Message, as a public link shows them.
  defp latest_reply(scope, task_id, task) do
    tail =
      case task["message_tail_seq"] || task["message_count"] do
        seq when is_integer(seq) and seq > 0 -> seq
        _ -> 0
      end

    with true <- tail > 0,
         {:ok, %{"messages" => messages}} when is_list(messages) <-
           Comma.Salix.Client.impl().get_group_conversation_with_messages(scope, task_id,
             after_seq: max(tail - 20, 0),
             limit: 20
           ) do
      messages
      |> Enum.flat_map(&Comma.TaskShares.public_message/1)
      |> Enum.filter(&(&1["role"] == "assistant"))
      |> List.last()
      |> case do
        nil ->
          nil

        message ->
          text =
            for %{"type" => "text", "text" => text} <- message["content"], into: "", do: text

          if text == "", do: nil, else: String.slice(text, 0, 4_000)
      end
    else
      _ -> nil
    end
  end

  defp owner_grant_view(%TaskRequestGrant{} = grant, users) do
    %{
      "id" => grant.id,
      "status" => grant.status,
      "mode" => grant.mode,
      "daily_limit" => grant.daily_limit,
      "pending_limit" => grant.pending_limit,
      "grantee" => person(users[grant.grantee_user_id]),
      "created_at" => unix(grant.inserted_at),
      "accepted_at" => unix(grant.accepted_at)
    }
    |> Map.merge(
      if grant.status == "invited",
        do: %{
          "invite_token" => grant.invite_token,
          "invite_expires_at" => unix(grant.invite_expires_at)
        },
        else: %{}
    )
  end

  defp target_view(grant, workspace, owners, counts, now) do
    {sent_today, pending} = Map.get(counts, grant.id, {0, 0})

    %{
      "grant_id" => grant.id,
      "workspace" => workspace_view(workspace, owners[workspace.owner_user_id]),
      "mode" => grant.mode,
      "daily_limit" => grant.daily_limit,
      "pending_limit" => grant.pending_limit,
      "sent_today" => sent_today,
      "pending" => pending,
      "accepted_at" => unix(grant.accepted_at || now)
    }
  end

  defp incoming_view(request, users, now) do
    %{
      "id" => request.id,
      "grant_id" => request.grant_id,
      "sender" => person(users[request.sender_user_id] || user(request.sender_user_id)),
      "title" => request.title,
      "content" => request.content,
      "status" => status(request, now),
      "accepted_as" => request.accepted_as,
      "decline_reason" => request.decline_reason,
      "task" => task_ref(request),
      "created_at" => unix(request.inserted_at),
      "expires_at" => unix(request.expires_at),
      "decided_at" => unix(request.decided_at)
    }
  end

  defp sent_view(request, workspaces, now, task_state) do
    workspace = workspaces[request.workspace_id]
    owner = if workspace, do: users([workspace.owner_user_id])[workspace.owner_user_id]

    %{
      "id" => request.id,
      "grant_id" => request.grant_id,
      "workspace" => if(workspace, do: workspace_view(workspace, owner)),
      "title" => request.title,
      "content" => request.content,
      "status" => status(request, now),
      "accepted_as" => request.accepted_as,
      "decline_reason" => request.decline_reason,
      "task_status" => task_state["task_status"],
      "reply" => task_state["reply"],
      "task_updated_at" => unix(request.task_updated_at),
      "created_at" => unix(request.inserted_at),
      "expires_at" => unix(request.expires_at),
      "decided_at" => unix(request.decided_at)
    }
  end

  defp task_ref(%TaskRequest{task_id: task_id, group_id: group_id}) when is_binary(task_id),
    do: %{"group_id" => group_id, "id" => task_id}

  defp task_ref(_request), do: nil

  defp workspace_view(%Workspace{} = workspace, owner),
    do: %{"id" => workspace.id, "name" => workspace.name, "owner" => person(owner)}

  defp person(nil), do: nil

  defp person(user),
    do: %{
      "id" => user.id,
      "name" => user.name,
      "email" => user.email,
      "avatar_id" => user.avatar_id
    }

  defp sender_name(nil), do: nil
  defp sender_name(user), do: user.name || user.email

  defp status(%TaskRequest{status: "pending"} = request, now),
    do: if(expired?(request, now), do: "expired", else: "pending")

  defp status(%TaskRequest{status: status}, _now), do: status

  defp expired?(%TaskRequest{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp users(ids) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if ids == [],
      do: %{},
      else:
        from(u in Comma.Accounts.User, where: u.id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
  end

  defp user(id) when is_binary(id), do: Repo.get(Comma.Accounts.User, id)
  defp user(_id), do: nil

  defp sent_workspaces(requests) do
    ids = requests |> Enum.map(& &1.workspace_id) |> Enum.uniq()

    from(w in Workspace, where: w.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # Today's sends (a sliding 24 hours) and pending requests per grant.
  defp usage([], _now), do: %{}

  defp usage(grant_ids, now) do
    since = DateTime.add(now, -86_400, :second)

    from(r in TaskRequest,
      where: r.grant_id in ^grant_ids and r.inserted_at > ^since,
      group_by: r.grant_id,
      select:
        {r.grant_id, count(r.id),
         fragment("count(*) FILTER (WHERE ? = 'pending' AND ? > ?)", r.status, r.expires_at, ^now)}
    )
    |> Repo.all()
    |> Map.new(fn {id, sent, pending} -> {id, {sent, pending}} end)
  end

  # An owner's own requests count per Workspace against the default limits.
  defp within_own_limits(workspace_id, user_id, now) do
    since = DateTime.add(now, -86_400, :second)

    own =
      from(r in TaskRequest,
        where:
          r.workspace_id == ^workspace_id and r.sender_user_id == ^user_id and
            is_nil(r.grant_id)
      )

    sent = Repo.one(from(r in own, where: r.inserted_at > ^since, select: count(r.id)))

    pending =
      Repo.one(
        from(r in own,
          where: r.status == "pending" and r.expires_at > ^now,
          select: count(r.id)
        )
      )

    cond do
      sent >= @default_daily_limit -> {:error, :task_request_daily_limit}
      pending >= @default_pending_limit -> {:error, :task_request_pending_limit}
      true -> :ok
    end
  end

  defp within_limits(grant, now) do
    since = DateTime.add(now, -86_400, :second)

    sent =
      Repo.one(
        from(r in TaskRequest,
          where: r.grant_id == ^grant.id and r.inserted_at > ^since,
          select: count(r.id)
        )
      )

    pending =
      Repo.one(
        from(r in TaskRequest,
          where: r.grant_id == ^grant.id and r.status == "pending" and r.expires_at > ^now,
          select: count(r.id)
        )
      )

    cond do
      sent >= grant.daily_limit -> {:error, :task_request_daily_limit}
      pending >= grant.pending_limit -> {:error, :task_request_pending_limit}
      true -> :ok
    end
  end

  # A decision the sender did not make reaches their clients.
  defp close_pending(request, status, now, extra \\ []) do
    closed =
      from(r in TaskRequest,
        where: r.id == ^request.id and r.status == "pending" and r.expires_at > ^now
      )
      |> Repo.update_all(set: [status: status, decided_at: now, updated_at: now] ++ extra)

    if match?({1, _}, closed) and status != "withdrawn", do: sent_changed(request.sender_user_id)
    closed
  end

  defp open_invite(token) do
    with true <- valid_token?(token),
         %TaskRequestGrant{status: "invited"} = grant <-
           Repo.get_by(TaskRequestGrant, invite_token: token),
         :gt <- DateTime.compare(grant.invite_expires_at, now()),
         %Workspace{status: "active", kind: "standard"} = workspace <-
           Repo.get(Workspace, grant.workspace_id) do
      {:ok, grant, workspace}
    else
      _ -> {:error, :not_found}
    end
  end

  defp get_grant(workspace_id, grant_id) when is_binary(grant_id),
    do: Repo.get_by(TaskRequestGrant, id: grant_id, workspace_id: workspace_id)

  defp get_grant(_workspace_id, _grant_id), do: nil

  defp get_incoming(workspace_id, request_id) when is_binary(request_id),
    do: Repo.get_by(TaskRequest, id: request_id, workspace_id: workspace_id)

  defp get_incoming(_workspace_id, _request_id), do: nil

  defp below_grant_limit(workspace_id) do
    count =
      Repo.one(
        from(g in TaskRequestGrant,
          where: g.workspace_id == ^workspace_id and g.status in ["invited", "active"],
          select: count(g.id)
        )
      )

    if count < @grant_limit, do: :ok, else: {:error, :task_request_grant_limit}
  end

  ## Authorization and input

  # The Workspace owner's own full session. A restricted session (a channel
  # panel cookie) manages nothing here.
  defp authorize_owner(user, session, workspace_id) do
    with :ok <- full_session(session),
         {:ok, %{"kind" => "standard"} = workspace} <-
           Workspaces.authorize(user, session, workspace_id) do
      {:ok, workspace}
    else
      {:ok, _guest} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp full_session(%{"restricted" => true}), do: {:error, :forbidden}
  defp full_session(_session), do: :ok

  defp settings(attrs, defaults) when is_map(attrs) do
    mode = Map.get(attrs, "mode", defaults[:mode] || "review")
    daily = Map.get(attrs, "daily_limit", defaults[:daily_limit] || @default_daily_limit)
    pending = Map.get(attrs, "pending_limit", defaults[:pending_limit] || @default_pending_limit)

    cond do
      mode not in @modes ->
        {:error, {:bad_request, "mode must be review or auto_accept"}}

      not (is_integer(daily) and daily in 1..@max_daily_limit) ->
        {:error, {:bad_request, "daily_limit must be between 1 and #{@max_daily_limit}"}}

      not (is_integer(pending) and pending in 1..@max_pending_limit) ->
        {:error, {:bad_request, "pending_limit must be between 1 and #{@max_pending_limit}"}}

      true ->
        {:ok, %{mode: mode, daily_limit: daily, pending_limit: pending}}
    end
  end

  defp settings(_attrs, _defaults), do: {:error, {:bad_request, "invalid task request grant"}}

  defp accept_edit(attrs) when is_map(attrs) do
    with {:ok, title} <- optional_text(attrs["title"], @title_bytes),
         {:ok, content} <- optional_text(attrs["content"], @content_bytes),
         true <- is_nil(attrs["runs_on"]) or is_map(attrs["runs_on"]),
         true <- is_nil(attrs["model"]) or is_map(attrs["model"]),
         true <- is_nil(attrs["repo"]) or is_map(attrs["repo"]),
         true <- is_nil(attrs["account_id"]) or is_binary(attrs["account_id"]),
         true <- attrs["to"] in [nil, "task", "router"],
         true <- attrs["to"] != "router" or (is_nil(attrs["runs_on"]) and is_nil(attrs["model"])) do
      {:ok,
       %{}
       |> put_present("to", attrs["to"])
       |> put_present("title", title)
       |> put_present("content", content)
       |> put_present("runs_on", attrs["runs_on"])
       |> put_present("model", attrs["model"])
       |> put_present("repo", attrs["repo"])
       |> put_present("account_id", attrs["account_id"])}
    else
      false -> {:error, {:bad_request, "invalid task request acceptance"}}
      {:error, _reason} = error -> error
    end
  end

  defp accept_edit(_attrs), do: {:error, {:bad_request, "invalid task request acceptance"}}

  defp incoming_filter(nil), do: {:ok, :pending}
  defp incoming_filter("pending"), do: {:ok, :pending}
  defp incoming_filter("all"), do: {:ok, :all}
  defp incoming_filter(_), do: {:error, {:bad_request, "status must be pending or all"}}

  defp required_text(value, max) do
    case optional_text(value, max) do
      {:ok, nil} -> {:error, {:bad_request, "content is required"}}
      other -> other
    end
  end

  defp optional_text(nil, _max), do: {:ok, nil}

  defp optional_text(value, max) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:ok, nil}

      not String.valid?(value) or byte_size(value) > max ->
        {:error, {:bad_request, "text is too long"}}

      String.contains?(value, <<0>>) ->
        {:error, {:bad_request, "text contains a null character"}}

      true ->
        {:ok, value}
    end
  end

  defp optional_text(_value, _max), do: {:error, {:bad_request, "text must be a string"}}

  defp client_request_id(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Za-z0-9_.:-]{1,128}\z/, value),
      do: {:ok, value},
      else: {:error, {:bad_request, "invalid client_request_id"}}
  end

  defp client_request_id(_value), do: {:error, {:bad_request, "client_request_id is required"}}

  defp title_of(content) do
    content
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp new_id(prefix),
    do: prefix <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

  defp new_token,
    do: @token_bytes |> SystemsRuntime.Proc.random_bytes() |> Base.url_encode64(padding: false)

  defp now, do: SystemsClock.utc_now()

  defp unix(%DateTime{} = value), do: DateTime.to_unix(value)
  defp unix(_value), do: nil
end
