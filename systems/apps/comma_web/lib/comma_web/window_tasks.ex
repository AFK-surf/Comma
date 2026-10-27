defmodule CommaWeb.WindowTasks do
  @moduledoc """
  Tasks in Comma's cloud that a Workspace's member starts from the New task
  window:

    * `POST /v1/comma/workspaces/:ws/tasks` `{text, model: {id, effort?},
      client_request_id}`: starts a Task, owned by the caller, that a model of
      the Workspace's catalog runs, with `text` its first Message
      (`SalixIM.ModelMentionTask.start_from_window/5`). The uploads `text`
      names (`(workspace file: /uploads/…)`, put in the Router's VFS by the
      window, as the composer's are) are shared into it first. Answers
      `{task_id, group_id}` as soon as the Task is made, so the window opens
      it at once: nothing is posted to Home. Made once per
      `client_request_id`.

  A read-only member (`viewer`) starts none. A Task the Workspace cannot run
  (its model, a file that could not be passed on) is refused (409) with why;
  a failure the same request may get past is 503 `task_unavailable`.
  """

  import Plug.Conn
  require Logger

  @text_bytes 16_000

  def start(conn, workspace_id) do
    started = SystemsClock.monotonic_time(:millisecond)

    with_member(conn, workspace_id, fn workspace, user ->
      body = conn.body_params || %{}

      with {:ok, text} <- text(body["text"]),
           {:ok, request_id} <- request_id(body["client_request_id"]),
           {:ok, model} <- model(body["model"]),
           group = workspace.salix_group_id,
           {:ok, router} <- router(group),
           {:ok, created} <-
             SalixIM.ModelMentionTask.start_from_window(
               group,
               router,
               user["id"],
               request_id,
               Map.put(model, :text, text)
             ) do
        Logger.info(
          "window task started group=#{group} ms=#{SystemsClock.monotonic_time(:millisecond) - started}"
        )

        json(conn, 201, %{task_id: created["conversation_id"], group_id: group})
      end
    end)
  end

  defp router(group) do
    case SalixIM.GroupDirectory.get_group(group) do
      {:ok, %{"router_agent_id" => router}} when is_binary(router) -> {:ok, router}
      {:ok, _group} -> {:error, :no_router}
      {:error, reason} -> {:error, {:group, reason}}
    end
  end

  # --- Access

  defp with_member(conn, workspace_id, fun) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} when is_map(user) and is_map(session) ->
        case Comma.Stations.member(user, session, workspace_id) do
          {:ok, _workspace, "viewer"} ->
            json(conn, 403, %{error: "forbidden"})

          {:ok, workspace, _role} ->
            case fun.(workspace, user) do
              %Plug.Conn{} = done -> done
              error -> error(conn, error)
            end

          {:error, :forbidden} ->
            json(conn, 403, %{error: "forbidden"})

          _ ->
            json(conn, 404, %{error: "not_found"})
        end

      _ ->
        json(conn, 401, %{error: "unauthorized"})
    end
  end

  # --- Input

  defp text(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, {:bad_request, "text is required"}}
      byte_size(text) > @text_bytes -> {:error, {:bad_request, "text is too long"}}
      true -> {:ok, text}
    end
  end

  defp text(_text), do: {:error, {:bad_request, "text is required"}}

  defp request_id(id) when is_binary(id) and byte_size(id) in 1..128, do: {:ok, id}
  defp request_id(_id), do: {:error, {:bad_request, "client_request_id is required"}}

  defp model(%{"id" => id} = model) when is_binary(id) and byte_size(id) in 1..256 do
    case model["effort"] do
      nil ->
        {:ok, %{model: id}}

      effort when is_binary(effort) and byte_size(effort) in 1..32 ->
        {:ok, %{model: id, effort: effort}}

      _effort ->
        {:error, {:bad_request, "model effort must be a name"}}
    end
  end

  defp model(_model), do: {:error, {:bad_request, "model must name a catalog model id"}}

  # --- Answers

  defp error(conn, {:error, {:bad_request, message}}),
    do: json(conn, 400, %{error: "bad_request", message: message})

  # A refusal is final: the window says why, and another try is another Task.
  # Anything else may pass when the same request comes again, and may even have
  # made the Task, so the window tries again under the same client_request_id.
  defp error(conn, {:error, reason}) do
    case SalixIM.ModelMentionTask.refusal_message(reason) do
      {:ok, message} ->
        Logger.info("window task refused reason=#{inspect(reason)}")
        json(conn, 409, %{error: "refused", message: message})

      :error ->
        Logger.warning("window task failed reason=#{inspect(reason)}")
        json(conn, 503, %{error: "task_unavailable"})
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
