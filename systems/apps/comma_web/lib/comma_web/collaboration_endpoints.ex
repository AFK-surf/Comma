defmodule CommaWeb.CollaborationEndpoints do
  @moduledoc """
  HTTP surface for Collaborative Tasks (`Comma.Collaborations`). Every route
  needs a signed-in session.

  The host (the Workspace owner):

    * `POST /v1/comma/workspaces/:ws/collaborations` `{people, content,
      title?, client_request_id}` starts one, answered with its `task`.
    * `GET /v1/comma/workspaces/:ws/collaborations/:task_id/members`; `DELETE
      …/members/:user_id` takes a member or an unanswered invite out.

  A person it was started with:

    * `GET /v1/comma/collaborations`: their invites and memberships.
    * `POST /v1/comma/collaborations/:id/accept|decline|leave`.
    * `GET /v1/comma/collaborations/:group_id/:task_id[?after_seq=]`, `GET|POST
      …/messages`, `GET …/events`: the Task, while they are an active member
      (served in `CommaWeb.Router` beside the Group's routes). These are the
      member's only routes to the host's Group; the `/v1/comma/groups/...`
      routes stay the Workspace's own.

  The host may also start one from their Router chat by naming People
  (`SalixIM.ShareMention`, through `start_from_router/5`).
  """

  @behaviour SalixIM.Ports.Collaborations

  import Plug.Conn

  require Logger

  alias Comma.Collaborations

  @impl SalixIM.Ports.Collaborations
  def start_from_router(group_id, user_id, people, content, key) do
    with {:ok, %{"id" => workspace_id, "owner_user_id" => ^user_id}} <-
           Comma.Workspaces.get_by_group(group_id),
         {:ok, user} <- Comma.Accounts.get_user(user_id),
         {:ok, %{"task" => task}} <-
           Collaborations.start(user, %{}, workspace_id, %{
             "people" => people,
             "content" => content,
             "client_request_id" => key
           }) do
      {:ok, %{"task_id" => task["id"], "group_id" => task["group_id"]}}
    else
      {:ok, _workspace} -> {:error, :forbidden}
      {:error, {:bad_request, "everyone must be among your People"}} -> {:error, :not_contact}
      {:error, {:billing_unavailable, _}} -> {:error, :billing_unavailable}
      {:error, _reason} = error -> error
    end
  end

  def start(conn, workspace_id),
    do: run(conn, 201, &Collaborations.start(&1, &2, workspace_id, body(conn)))

  def members(conn, workspace_id, task_id),
    do: run(conn, 200, &Collaborations.members(&1, &2, workspace_id, task_id), &%{"data" => &1})

  def remove(conn, workspace_id, task_id, user_id),
    do:
      run(
        conn,
        200,
        fn user, session ->
          with :ok <- Collaborations.remove(user, session, workspace_id, task_id, user_id),
               do: {:ok, %{"removed" => true}}
        end
      )

  def resend(conn, workspace_id, task_id, member_id),
    do: run(conn, 200, &Collaborations.resend_invite(&1, &2, workspace_id, task_id, member_id))

  def list(conn), do: run(conn, 200, &Collaborations.list/2, &%{"data" => &1})
  def accept(conn, id), do: run(conn, 200, &Collaborations.accept(&1, &2, id))
  def decline(conn, id), do: run(conn, 200, &told(Collaborations.decline(&1, &2, id)))
  def leave(conn, id), do: run(conn, 200, &told(Collaborations.leave(&1, &2, id)))

  def member_avatar(conn, group_id, task_id, user_id, avatar_id) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} when is_map(user) and is_map(session) ->
        case Collaborations.member_avatar(user, session, group_id, task_id, user_id, avatar_id) do
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

  # The host hears in Home that a member declined or left
  # (`CommaWeb.CollaborationNotice`). The answer is already kept: a notice that
  # cannot be queued changes nothing of it.
  defp told({:ok, row} = result) do
    with {:error, reason} <- CommaWeb.CollaborationNotice.member_changed(row) do
      Logger.warning("collaboration notice not queued reason=#{inspect(reason)}")
    end

    result
  end

  defp told(result), do: result

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
  defp error(conn, :conflict), do: json(conn, 409, %{error: "conflict"})

  defp error(conn, {:rate_limited, :invite_daily_limit_reached, retry_after}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> json(429, %{
      error: "invite_daily_limit_reached",
      limit: 20,
      retry_after_seconds: retry_after
    })
  end

  defp error(conn, {:billing_unavailable, decision}) do
    {status, body} = CommaWeb.BillingErrors.billing_response(decision)
    json(conn, status, body)
  end

  defp error(conn, {:task_model_selection_failed, message}) do
    {status, body} = CommaWeb.BillingErrors.task_model_selection_response(message)
    json(conn, status, body)
  end

  # A Task, invite or member the caller may not see is one that does not exist.
  defp error(conn, reason) when reason in [:not_found, :workspace_not_found],
    do: json(conn, 404, %{error: "not_found"})

  defp error(conn, _reason), do: json(conn, 503, %{error: "collaborations_unavailable"})

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
