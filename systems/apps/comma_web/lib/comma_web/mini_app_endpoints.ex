defmodule CommaWeb.MiniAppEndpoints do
  @moduledoc """
  HTTP surface of Mini Apps (`Comma.MiniApps`). Errors are
  `{"error": reason, "message"?: text}`.

  Workspace routes (`/v1/comma/workspaces/:ws/apps…`) need a member of `:ws`;
  writes need a member who is not read-only; owner actions need a member of
  the app's Workspace who sees the app.

  Link routes (`/v1/comma/apps/links/:token…`) and runtime routes
  (`/v1/comma/apps/:id/…`) need a Comma session, registered or guest. A
  runtime call names its access path in `x-comma-app-via`
  (`workspace/<id>` or `link/<token>`; guests only the latter). An owner
  Workspace member may name a preview Version in `x-comma-app-version`.
  Every link and runtime call passes the per-peer and per-app rate limit
  (`Comma.MiniApps.RateLimit`, fail closed).
  """

  import Plug.Conn
  require Logger

  alias Comma.MiniApps
  alias Comma.MiniApps.{AI, Blobs, Documents, RateLimit, Viewer}
  alias Comma.MiniApps.Drive, as: MiniAppDrive
  alias Comma.MiniApps.Web, as: MiniAppWeb
  alias CommaWeb.{MiniAppBackend, MiniAppPort}

  @backend_path ~r{\A/v1/comma/apps/[^/]+/backend(/|\z)}
  @backend_body_max 1024 * 1024
  @drive_file_path ~r{\A/v1/comma/apps/[^/]+/drive/file\z}
  @drive_body_max 20 * 1024 * 1024

  ## Body capture for backend forwarding

  @doc """
  Plug (before `Plug.Parsers`): a backend call's body (at most 1 MiB) and a
  Drive file write (at most 20 MiB) are the app's own, of any type. They are
  read raw into `:mini_app_body` with its
  content type in `:mini_app_content_type`, and the parsers see none.
  """
  def capture_backend_body(%Plug.Conn{method: method} = conn, _opts) do
    max =
      cond do
        method == "POST" and Regex.match?(@backend_path, conn.request_path) -> @backend_body_max
        method == "PUT" and Regex.match?(@drive_file_path, conn.request_path) -> @drive_body_max
        true -> nil
      end

    if max do
      content_type = conn |> get_req_header("content-type") |> List.first()

      case read_body(conn, length: max, read_length: 1_048_576) do
        {:ok, body, conn} ->
          conn
          |> assign(:mini_app_body, body)
          |> assign(:mini_app_content_type, content_type)
          |> put_req_header("content-type", "application/octet-stream")

        {:more, _partial, conn} ->
          conn |> json(413, %{error: "body_too_large"}) |> halt()

        {:error, _} ->
          conn |> json(400, %{error: "invalid"}) |> halt()
      end
    else
      conn
    end
  end

  ## Workspace routes

  def list(conn, ws) do
    with_user(conn, fn user, session ->
      with {:ok, apps} <- MiniApps.list(user, session, ws), do: json(conn, 200, %{data: apps})
    end)
  end

  def create(conn, ws) do
    with_user(conn, fn user, session ->
      with {:ok, workspace, _role} <- MiniApps.member(user, session, ws, :write),
           {:ok, app} <- MiniAppPort.create_app(workspace, user["id"], body(conn)) do
        json(conn, 201, MiniApps.view_one(app, workspace.id))
      end
    end)
  end

  def show(conn, ws, id) do
    with_user(conn, fn user, session ->
      with {:ok, app} <- MiniApps.show(user, session, ws, id), do: json(conn, 200, app)
    end)
  end

  def update(conn, ws, id) do
    with_user(conn, fn user, session ->
      with {:ok, app} <- MiniApps.update(user, session, ws, id, body(conn)),
           do: json(conn, 200, app)
    end)
  end

  def delete(conn, ws, id) do
    with_user(conn, fn user, session ->
      with {:ok, :ok} <- MiniApps.delete(user, session, ws, id),
           do: json(conn, 200, %{status: "deleted"})
    end)
  end

  def publish(conn, ws, id) do
    with_user(conn, fn user, session ->
      with {:ok, app} <- CommaWeb.MiniAppPublishing.publish(user, session, ws, id, body(conn)),
           do: json(conn, 200, app)
    end)
  end

  def rollback(conn, ws, id) do
    with_user(conn, fn user, session ->
      with {:ok, app} <- MiniApps.rollback(user, session, ws, id, body(conn)["version"]),
           do: json(conn, 200, app)
    end)
  end

  def disable(conn, ws, id) do
    with_user(conn, fn user, session ->
      with {:ok, app} <- MiniApps.disable(user, session, ws, id), do: json(conn, 200, app)
    end)
  end

  def enable(conn, ws, id) do
    with_user(conn, fn user, session ->
      with {:ok, app} <- MiniApps.enable(user, session, ws, id), do: json(conn, 200, app)
    end)
  end

  def get_link(conn, ws, id) do
    with_user(conn, fn user, session ->
      case MiniApps.get_link(user, session, ws, id) do
        {:ok, nil} -> json(conn, 200, %{link: nil})
        {:ok, link} -> json(conn, 200, MiniApps.link_view(link))
        error -> error
      end
    end)
  end

  def put_link(conn, ws, id) do
    with_user(conn, fn user, session ->
      with {:ok, link} <- MiniApps.put_link(user, session, ws, id),
           do: json(conn, 200, MiniApps.link_view(link))
    end)
  end

  def reset_link(conn, ws, id) do
    with_user(conn, fn user, session ->
      with {:ok, link} <- MiniApps.reset_link(user, session, ws, id),
           do: json(conn, 200, MiniApps.link_view(link))
    end)
  end

  def delete_link(conn, ws, id) do
    with_user(conn, fn user, session ->
      with :ok <- MiniApps.revoke_link(user, session, ws, id), do: json(conn, 200, %{link: nil})
    end)
  end

  def put_grants(conn, ws, id) do
    with_user(conn, fn user, session ->
      with {:ok, app} <- MiniApps.put_grants(user, session, ws, id, body(conn)["grants"]),
           do: json(conn, 200, app)
    end)
  end

  def put_secret(conn, ws, id, name) do
    with_user(conn, fn user, session ->
      with {:ok, result} <-
             MiniApps.put_secret(user, session, ws, id, name, body(conn)["value"]),
           do: json(conn, 200, result)
    end)
  end

  def delete_secret(conn, ws, id, name) do
    with_user(conn, fn user, session ->
      with {:ok, result} <- MiniApps.delete_secret(user, session, ws, id, name),
           do: json(conn, 200, result)
    end)
  end

  def install(conn, ws) do
    with_user(conn, fn user, session ->
      body = body(conn)

      with {:ok, app} <-
             MiniApps.install(user, session, ws, body["token"], body["pinned_version"]),
           do: json(conn, 200, app)
    end)
  end

  def uninstall(conn, ws, id) do
    with_user(conn, fn user, session ->
      with :ok <- MiniApps.uninstall(user, session, ws, id),
           do: json(conn, 200, %{status: "removed"})
    end)
  end

  def remix(conn, ws) do
    with_user(conn, fn user, session ->
      with {:ok, result} <- MiniAppPort.remix(user, session, ws, body(conn)["token"]),
           do: json(conn, 201, result)
    end)
  end

  def report(conn, ws, id) do
    with_user(conn, fn user, session ->
      with :ok <- MiniApps.report(user, session, ws, id, body(conn)["reason"]),
           do: json(conn, 200, %{status: "reported"})
    end)
  end

  def version_bundle(conn, ws, id, number) do
    with_user(conn, fn user, session ->
      with {:ok, app, version} <- MiniApps.workspace_bundle(user, session, ws, id, number),
           do: send_bundle(conn, app, version)
    end)
  end

  ## Link routes

  def link(conn, token) do
    with_link(conn, token, fn _user, _session ->
      with {:ok, summary} <- MiniApps.link_summary(token), do: json(conn, 200, summary)
    end)
  end

  def link_bundle(conn, token) do
    with_link(conn, token, fn _user, _session ->
      with {:ok, app, version} <- MiniApps.link_bundle(token), do: send_bundle(conn, app, version)
    end)
  end

  ## Runtime routes

  def open(conn, id) do
    with_runtime(conn, id, fn user, session ->
      with {:ok, opened} <- MiniApps.open(user, session, id, via(conn), requested(conn)),
           do: json(conn, 200, opened)
    end)
  end

  def backend(conn, id, path) do
    with_runtime(conn, id, fn user, session ->
      method = conn |> get_req_header("x-comma-app-method") |> List.first() |> upcase()

      with true <- method in MiniAppBackend.methods() || {:error, :invalid},
           {:ok, rt} <- MiniApps.runtime(user, session, id, via(conn), requested(conn)),
           :ok <- MiniApps.owner_available(rt.app, "backend"),
           {:ok, viewer} <- Viewer.id(user["id"], rt.app.id),
           {:ok, answer} <-
             MiniAppBackend.forward(
               rt,
               viewer,
               method,
               path,
               conn.query_string,
               conn.assigns[:mini_app_content_type],
               conn.assigns[:mini_app_body] || ""
             ) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type(answer.content_type || "application/octet-stream", nil)
        |> send_resp(answer.status, answer.body)
      end
    end)
  end

  def storage_list(conn, id, scope) do
    with_storage(conn, id, scope, false, fn rt_scope, app_id ->
      with {:ok, page} <- Documents.list(app_id, rt_scope, conn.query_params),
           do: json(conn, 200, page)
    end)
  end

  def storage_get(conn, id, scope, key) do
    with_storage(conn, id, scope, false, fn rt_scope, app_id ->
      with {:ok, doc} <- Documents.get(app_id, rt_scope, Enum.join(key, "/")),
           do: json(conn, 200, doc)
    end)
  end

  def storage_put(conn, id, scope, key) do
    with_storage(conn, id, scope, true, fn rt_scope, app_id ->
      body = body(conn)

      with {:ok, doc} <-
             Documents.put(
               app_id,
               rt_scope,
               Enum.join(key, "/"),
               body["value"],
               body["if_version"]
             ),
           do: json(conn, 200, doc)
    end)
  end

  def storage_delete(conn, id, scope, key) do
    with_storage(conn, id, scope, true, fn rt_scope, app_id ->
      with :ok <- Documents.delete(app_id, rt_scope, Enum.join(key, "/")),
           do: json(conn, 200, %{status: "deleted"})
    end)
  end

  def ai_chat(conn, id) do
    with_runtime(conn, id, fn user, session ->
      with {:ok, rt} <- MiniApps.runtime(user, session, id, via(conn), requested(conn)),
           {:ok, message} <- AI.chat(user, rt, body(conn)["messages"]),
           do: json(conn, 200, %{message: message})
    end)
  end

  def web_search(conn, id) do
    with_runtime(conn, id, fn user, session ->
      with {:ok, rt} <- MiniApps.runtime(user, session, id, via(conn), requested(conn)),
           {:ok, results} <- MiniAppWeb.search(rt, body(conn)["query"]),
           do: json(conn, 200, %{results: results})
    end)
  end

  def ai_decide(conn, id) do
    with_runtime(conn, id, fn user, session ->
      with {:ok, rt} <- MiniApps.runtime(user, session, id, via(conn), requested(conn)),
           {:ok, answer} <- AI.decide(user, rt, body(conn)),
           do: json(conn, 200, answer)
    end)
  end

  def icon(conn, id) do
    with_runtime(conn, id, fn user, session ->
      with {:ok, body, type} <-
             MiniApps.icon(user, session, id, via(conn), conn.query_params["v"]) do
        conn
        |> put_resp_header("cache-control", "private, max-age=86400")
        |> put_resp_header("content-security-policy", "sandbox")
        |> put_resp_content_type(type, nil)
        |> send_resp(200, body)
      end
    end)
  end

  # A ready Version's cover never changes, and `cover_url` names the Version.
  def cover(conn, id) do
    with_runtime(conn, id, fn user, session ->
      with {:ok, body, type} <-
             MiniApps.cover(user, session, id, via(conn), conn.query_params["v"]) do
        conn
        |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
        |> put_resp_header("content-security-policy", "sandbox")
        |> put_resp_content_type(type, nil)
        |> send_resp(200, body)
      end
    end)
  end

  ## App folder in the viewer Workspace's Drive (`drive.app_folder`)

  def drive_list(conn, id) do
    with_drive(conn, id, false, fn group, app ->
      with {:ok, path} <- MiniAppDrive.path(app, conn.query_params["path"] || ""),
           {:ok, entries} <- MiniAppDrive.list(group, path),
           do: json(conn, 200, %{data: entries})
    end)
  end

  def drive_read(conn, id) do
    with_drive(conn, id, false, fn group, app ->
      with {:ok, path} <- MiniAppDrive.path(app, conn.query_params["path"] || ""),
           true <- path != MiniAppDrive.folder(app.name) || {:error, :invalid},
           {:ok, body} <- MiniAppDrive.read(group, path) do
        type = MIME.from_path(path)

        conn
        |> put_resp_header("content-security-policy", "sandbox")
        |> put_resp_content_type(type, nil)
        |> send_resp(200, body)
      end
    end)
  end

  def drive_write(conn, id) do
    with_drive(conn, id, true, fn group, app ->
      with {:ok, path} <- MiniAppDrive.path(app, conn.query_params["path"] || ""),
           true <- path != MiniAppDrive.folder(app.name) || {:error, :invalid},
           :ok <- MiniAppDrive.write(group, path, conn.assigns[:mini_app_body] || ""),
           do: json(conn, 200, %{status: "ok"})
    end)
  end

  def drive_delete(conn, id) do
    with_drive(conn, id, true, fn group, app ->
      with {:ok, path} <- MiniAppDrive.path(app, conn.query_params["path"] || ""),
           true <- path != MiniAppDrive.folder(app.name) || {:error, :invalid},
           :ok <- MiniAppDrive.delete(group, path),
           do: json(conn, 200, %{status: "deleted"})
    end)
  end

  # A Workspace viewer with the capability granted; writes need the owner's billing.
  defp with_drive(conn, id, write?, fun) do
    with_runtime(conn, id, fn user, session ->
      with {:ok, rt} <- MiniApps.runtime(user, session, id, via(conn), requested(conn)),
           :ok <- MiniAppDrive.access(rt),
           :ok <- if(write?, do: MiniApps.owner_available(rt.app, "drive"), else: :ok) do
        fun.(rt.workspace.salix_group_id, rt.app)
      end
    end)
  end

  ## Admin (platform takedown)

  @doc "Platform disable or enable of one app, for `CommaWeb.Router`'s audited admin command."
  def admin_command(:disable, app_id), do: MiniApps.platform_disable(app_id)
  def admin_command(:enable, app_id), do: MiniApps.platform_enable(app_id)

  ## Helpers

  defp with_storage(conn, id, scope, write?, fun) do
    with_runtime(conn, id, fn user, session ->
      with {:ok, rt} <- MiniApps.runtime(user, session, id, via(conn), requested(conn)),
           {:ok, rt_scope} <- MiniApps.storage_scope(rt, scope, user),
           :ok <- if(write?, do: MiniApps.owner_available(rt.app, "storage"), else: :ok) do
        fun.(rt_scope, rt.app.id)
      end
    end)
  end

  defp send_bundle(conn, app, version) do
    case Blobs.stream(Blobs.bundle_key(app.id, version.number)) do
      {:ok, stream} ->
        conn =
          conn
          |> put_resp_header("x-comma-bundle-digest", version.digest || "")
          |> put_resp_header("x-comma-app-version", Integer.to_string(version.number))
          |> put_resp_header("cache-control", "private, no-store")
          |> put_resp_content_type("application/x-tar", nil)
          |> send_chunked(200)

        Enum.reduce_while(stream, conn, fn chunk, conn ->
          case chunk(conn, chunk) do
            {:ok, conn} -> {:cont, conn}
            {:error, _} -> {:halt, conn}
          end
        end)

      {:error, :not_found} ->
        json(conn, 404, %{error: "not_found"})

      {:error, _} ->
        json(conn, 503, %{error: "temporarily_unavailable"})
    end
  end

  defp via(conn), do: conn |> get_req_header("x-comma-app-via") |> List.first()

  defp requested(conn) do
    case conn |> get_req_header("x-comma-app-version") |> List.first() do
      nil -> nil
      value -> with {:ok, n} <- MiniApps.positive(value), do: n, else: (_ -> nil)
    end
  end

  defp upcase(nil), do: "GET"
  defp upcase(value), do: String.upcase(value)

  defp body(conn) do
    case conn.body_params do
      %{} = params -> params
      _ -> %{}
    end
  end

  defp with_user(conn, fun) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} when is_map(user) and is_map(session) ->
        case fun.(user, session) do
          %Plug.Conn{} = done -> done
          other -> error(conn, other)
        end

      _ ->
        json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp with_link(conn, token, fun) do
    with_user(conn, fn user, session ->
      key = if MiniApps.valid_token?(token), do: {:link, token}, else: :invalid
      limited(conn, key, fn -> fun.(user, session) end)
    end)
  end

  defp with_runtime(conn, id, fun) do
    with_user(conn, fn user, session ->
      conn = put_resp_header(conn, "cache-control", "no-store")
      limited(conn, {:app, id}, fn -> fun.(user, session) end)
    end)
  end

  defp limited(conn, key, fun) do
    case RateLimit.check(conn.remote_ip, key) do
      :allow ->
        fun.()

      {:deny, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> json(429, %{error: "rate_limited"})

      {:unavailable, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> json(503, %{error: "temporarily_unavailable"})
    end
  end

  @deploy_first "Deploy the latest changes first"

  defp error(conn, {:error, reason}), do: error_reason(conn, reason)
  defp error(conn, {:ok, _unexpected}), do: json(conn, 500, %{error: "internal"})
  defp error(conn, other), do: error_reason(conn, other)

  defp error_reason(conn, :not_found), do: json(conn, 404, %{error: "not_found"})
  defp error_reason(conn, :forbidden), do: json(conn, 403, %{error: "forbidden"})
  defp error_reason(conn, :app_paused), do: json(conn, 402, %{error: "app_paused"})
  defp error_reason(conn, :signup_required), do: json(conn, 403, %{error: "signup_required"})
  defp error_reason(conn, :not_granted), do: json(conn, 403, %{error: "not_granted"})
  defp error_reason(conn, :unsupported), do: json(conn, 403, %{error: "unsupported"})
  defp error_reason(conn, :unavailable), do: json(conn, 503, %{error: "unavailable"})
  defp error_reason(conn, :rate_limited), do: json(conn, 429, %{error: "rate_limited"})

  defp error_reason(conn, :too_large),
    do: json(conn, 413, %{error: "too_large", message: "a Drive file is at most 20 MiB"})

  defp error_reason(conn, :invalid), do: json(conn, 400, %{error: "invalid"})
  defp error_reason(conn, :version_conflict), do: json(conn, 409, %{error: "version_conflict"})
  defp error_reason(conn, :quota_exceeded), do: json(conn, 413, %{error: "quota_exceeded"})

  defp error_reason(conn, :value_too_large),
    do: json(conn, 413, %{error: "quota_exceeded", message: "a value is at most 1 MiB"})

  defp error_reason(conn, :response_too_large),
    do: json(conn, 502, %{error: "failed", message: "the backend answer is larger than 5 MiB"})

  defp error_reason(conn, :deploy_latest_first),
    do: json(conn, 409, %{error: "deploy_latest_first", message: @deploy_first})

  defp error_reason(conn, {:bad_request, message}),
    do: json(conn, 400, %{error: "bad_request", message: message})

  defp error_reason(conn, {:conflict, message}),
    do: json(conn, 409, %{error: "conflict", message: message})

  defp error_reason(conn, {:too_large, message}),
    do: json(conn, 413, %{error: "too_large", message: message})

  defp error_reason(conn, {:repo_not_found, repo}),
    do:
      json(conn, 404, %{
        error: "repo_not_found",
        message: "#{repo} is not reachable or has no comma-app.json"
      })

  defp error_reason(conn, reason)
       when reason in [:github_not_connected, :github_reauthorization_required],
       do: json(conn, 409, %{error: to_string(reason)})

  defp error_reason(conn, {:github, status, message}),
    do: json(conn, 422, %{error: "github_refused", status: status, message: message})

  defp error_reason(conn, {:github, status}),
    do: json(conn, 502, %{error: "github_failed", status: status})

  defp error_reason(conn, {:runs_on, _reason, _source} = refusal),
    do: json(conn, 409, %{error: "refused", message: SalixIM.TaskPlacement.message(refusal)})

  defp error_reason(conn, {:billing_unavailable, reason}),
    do: json(conn, 402, %{error: "billing_unavailable", reason: to_string(reason)})

  defp error_reason(conn, :invalid_review_version),
    do: json(conn, 409, %{error: "invalid_review_version"})

  defp error_reason(conn, reason) do
    Logger.info("mini app request failed: #{inspect(reason) |> String.slice(0, 300)}")
    json(conn, 503, %{error: "temporarily_unavailable"})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
