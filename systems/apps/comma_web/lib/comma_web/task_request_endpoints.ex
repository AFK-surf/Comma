defmodule CommaWeb.TaskRequestEndpoints do
  @moduledoc """
  HTTP surface for Task Requests (`Comma.TaskRequests`). Every route needs a
  signed-in session.

  The receiving Workspace's owner:

    * `GET|POST /v1/comma/workspaces/:ws/task-request-grants`: the open
      invites and active grants; a new invite `{mode?, daily_limit?,
      pending_limit?}`, answered with its `invite_url`.
    * `PATCH|DELETE …/task-request-grants/:id`: change a grant's mode or
      limits; revoke it.
    * `GET|PATCH /v1/comma/workspaces/:ws/task-request-own` `{mode}`: how the
      owner's own requests (from a chat app linked to them) are taken.
    * `GET /v1/comma/workspaces/:ws/task-requests?status=pending|all`.
    * `POST …/task-requests/:id/accept` `{title?, content?, runs_on?, model?}`
      creates the Task; `POST …/task-requests/:id/decline` `{reason?}`.

  The sender:

    * `GET /v1/comma/task-request-invites/:token?workspace_id=`: whose invite
      it is and what accepting it there gives the inviter (`back`);
      `POST …/:token/accept` `{workspace_id?}` makes its grant the caller's;
      with `workspace_id`, the caller's own Workspace, the inviter may send
      back to it (`reciprocal`).
    * `GET /v1/comma/task-request-targets`: where the caller may send;
      `POST …/task-request-targets/:grant_id/requests` `{content, title?,
      client_request_id}` sends one.
    * `GET /v1/comma/sent-task-requests[/:id]`, `POST …/:id/withdraw`.

  A chat app's user linking their Comma account (`Comma.ProviderUserLinks`):

    * `GET /v1/comma/provider-link-requests/:token`: which chat account a link
      names; `POST …/:token/accept` links it to the caller.
    * `GET /v1/comma/provider-links`, `DELETE …/:id`: the caller's links.
  """

  import Plug.Conn

  alias Comma.TaskRequests

  # The invite opens Settings › Task requests with the token filled in.
  @invite_path "/#/settings?category=task-requests&invite="

  def list_grants(conn, workspace_id),
    do:
      run(
        conn,
        200,
        &TaskRequests.list_grants(&1, &2, workspace_id),
        &Enum.map(&1, fn g -> grant_json(g) end)
      )

  def create_invite(conn, workspace_id),
    do:
      run(conn, 201, &TaskRequests.create_invite(&1, &2, workspace_id, body(conn)), &grant_json/1)

  def update_grant(conn, workspace_id, grant_id),
    do:
      run(
        conn,
        200,
        &TaskRequests.update_grant(&1, &2, workspace_id, grant_id, body(conn)),
        &grant_json/1
      )

  def revoke_grant(conn, workspace_id, grant_id) do
    run(conn, 200, fn user, session ->
      with :ok <- TaskRequests.revoke_grant(user, session, workspace_id, grant_id),
           do: {:ok, %{"revoked" => true}}
    end)
  end

  def own_mode(conn, workspace_id),
    do: run(conn, 200, &TaskRequests.own_mode(&1, &2, workspace_id))

  def set_own_mode(conn, workspace_id),
    do: run(conn, 200, &TaskRequests.set_own_mode(&1, &2, workspace_id, body(conn)))

  def list_incoming(conn, workspace_id) do
    run(conn, 200, fn user, session ->
      with {:ok, requests} <-
             TaskRequests.list_incoming(user, session, workspace_id,
               status: conn.query_params["status"]
             ),
           do: {:ok, %{"data" => requests}}
    end)
  end

  def accept(conn, workspace_id, request_id),
    do: run(conn, 200, &TaskRequests.accept_request(&1, &2, workspace_id, request_id, body(conn)))

  def decline(conn, workspace_id, request_id),
    do:
      run(conn, 200, &TaskRequests.decline_request(&1, &2, workspace_id, request_id, body(conn)))

  def sender_avatar(conn, workspace_id, request_id, avatar_id),
    do:
      avatar(
        conn,
        &TaskRequests.sender_avatar(&1, &2, workspace_id, request_id, avatar_id)
      )

  def recipient_avatar(conn, request_id, avatar_id),
    do: avatar(conn, &TaskRequests.recipient_avatar(&1, &2, request_id, avatar_id))

  def target_avatar(conn, grant_id, avatar_id),
    do: avatar(conn, &TaskRequests.target_avatar(&1, &2, grant_id, avatar_id))

  defp avatar(conn, read) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} when is_map(user) and is_map(session) ->
        case read.(user, session) do
          {:ok, content_type, body} ->
            conn
            |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
            |> put_resp_content_type(content_type)
            |> send_resp(200, body)

          {:error, reason} ->
            error(conn, reason)
        end

      _ ->
        json(conn, 401, %{error: "unauthorized"})
    end
  end

  def invite(conn, token),
    do: run(conn, 200, &TaskRequests.invite_preview(&1, &2, token, conn.query_params))

  def accept_invite(conn, token),
    do: run(conn, 200, &TaskRequests.accept_invite(&1, &2, token, body(conn)))

  def targets(conn) do
    run(conn, 200, fn user, session ->
      with {:ok, targets} <- TaskRequests.list_targets(user, session),
           do: {:ok, %{"data" => targets}}
    end)
  end

  def send_request(conn, grant_id),
    do: run(conn, 201, &TaskRequests.send_request(&1, &2, grant_id, body(conn)))

  def sent(conn) do
    run(conn, 200, fn user, session ->
      with {:ok, requests} <- TaskRequests.list_sent(user, session),
           do: {:ok, %{"data" => requests}}
    end)
  end

  def get_sent(conn, request_id), do: run(conn, 200, &TaskRequests.get_sent(&1, &2, request_id))

  def withdraw(conn, request_id), do: run(conn, 200, &TaskRequests.withdraw(&1, &2, request_id))

  def link_preview(conn, token),
    do: run(conn, 200, &Comma.ProviderUserLinks.preview(&1, &2, token))

  def accept_link(conn, token),
    do: run(conn, 200, &Comma.ProviderUserLinks.accept(&1, &2, token))

  def links(conn) do
    run(conn, 200, fn user, session ->
      with {:ok, links} <- Comma.ProviderUserLinks.list(user, session),
           do: {:ok, %{"data" => links}}
    end)
  end

  def remove_link(conn, link_id) do
    run(conn, 200, fn user, session ->
      with :ok <- Comma.ProviderUserLinks.remove(user, session, link_id),
           do: {:ok, %{"removed" => true}}
    end)
  end

  @doc "The web URL that opens an invite token."
  def invite_url(token) do
    String.trim_trailing(SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin), "/") <>
      @invite_path <> token
  end

  defp grant_json(grant) do
    case Map.pop(grant, "invite_token") do
      {token, grant} when is_binary(token) -> Map.put(grant, "invite_url", invite_url(token))
      {_none, grant} -> grant
    end
  end

  defp run(conn, status, fun, present \\ & &1) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} when is_map(user) and is_map(session) ->
        case fun.(user, session) do
          {:ok, value} -> json(conn, status, present.(value))
          {:error, reason} -> error(conn, reason)
        end

      _ ->
        json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp error(conn, {:bad_request, message}), do: json(conn, 400, %{error: message})
  defp error(conn, :forbidden), do: json(conn, 403, %{error: "forbidden"})

  # The Router chat Message is billed like any the owner writes there.
  defp error(conn, {:billing_unavailable, _decision}),
    do: json(conn, 402, %{error: "billing_unavailable"})

  defp error(conn, :own_workspace), do: json(conn, 409, %{error: "own_workspace"})

  defp error(conn, reason)
       when reason in [
              :task_request_closed,
              :task_request_expired,
              :task_request_grant_limit
            ],
       do: json(conn, 409, %{error: Atom.to_string(reason)})

  defp error(conn, reason)
       when reason in [:task_request_daily_limit, :task_request_pending_limit],
       do: json(conn, 429, %{error: Atom.to_string(reason)})

  # The place or model the owner chose for the Task cannot be used.
  defp error(conn, {kind, _reason, _source} = refusal) when kind == :runs_on,
    do:
      json(conn, 422, %{
        error: "task_run_refused",
        message: SalixIM.TaskPlacement.message(refusal)
      })

  defp error(conn, {:model, _reason} = refusal),
    do:
      json(conn, 422, %{
        error: "task_run_refused",
        message: SalixIM.TaskPlacement.message(refusal)
      })

  defp error(conn, reason) when reason in [:not_found, :workspace_not_found],
    do: json(conn, 404, %{error: "not_found"})

  defp error(conn, _reason), do: json(conn, 503, %{error: "task_requests_unavailable"})

  defp body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> %{}
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
