defmodule CommaWeb.CollaborationGuestEndpoints do
  @moduledoc """
  Public HTTP surface for external email guests invited to a Collaborative Task
  (`/v1/comma/public/collaborations/...`).

  Routes bypass Comma session auth in `CommaWeb.Auth`:
  - Invite preview & OTP routes authenticate via the 7-day `invite_token`.
  - Task routes authenticate via `Authorization: Bearer cgs_...` (and `?token=cgs_...`
    for SSE `/events` and browser `/files/download`), re-validated on EVERY
    request against `comma_collaboration_guest_sessions` and `comma_task_collaborators`.
  """

  import Plug.Conn

  require Logger
  require SystemsClock
  require SystemsRuntime.Proc

  alias Comma.CollaborationGuests

  @public_prefix "/v1/comma/public/collaborations/"
  @content_bytes 16_000
  @task_file_max_bytes 25 * 1024 * 1024
  @max_sse_wait_ms 30_000
  @sse_heartbeat_ms 15_000

  @spec public_path?(String.t()) :: boolean()
  def public_path?(path) when is_binary(path), do: String.starts_with?(path, @public_prefix)
  def public_path?(_path), do: false

  def put_public_cors(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET,POST,OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization,content-type,range")
    |> put_resp_header("access-control-expose-headers", "accept-ranges,content-range,retry-after")
    |> put_resp_header("access-control-max-age", "600")
    |> send_resp(204, "")
    |> halt()
  end

  def put_public_cors(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-expose-headers", "accept-ranges,content-range,retry-after")
  end

  ## Unauthenticated invite + OTP endpoints

  def invite_preview(conn, token) do
    case CollaborationGuests.invite_preview(token) do
      {:ok, payload} -> send_public_json(conn, 200, payload)
      {:error, reason} -> invite_error(conn, reason)
    end
  end

  def request_otp(conn, token) do
    request_attrs = %{"remote_ip" => remote_ip(conn)}

    case CollaborationGuests.request_otp(token, body(conn), request_attrs) do
      {:ok, payload} ->
        send_public_json(conn, 200, payload)

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_public_json(429, %{
          "error" => "rate_limited",
          "retry_after_seconds" => retry_after
        })

      {:error, :provider_unavailable, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_public_json(503, %{"error" => "email_delivery_unavailable"})

      {:error, reason} ->
        invite_error(conn, reason)
    end
  end

  def verify_otp(conn, token) do
    case CollaborationGuests.verify_otp(token, body(conn)) do
      {:ok, payload} ->
        send_public_json(conn, 200, payload)

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_public_json(429, %{
          "error" => "rate_limited",
          "retry_after_seconds" => retry_after
        })

      {:error, :invalid_verification_code} ->
        send_public_json(conn, 401, %{"error" => "invalid_code"})

      {:error, reason} ->
        invite_error(conn, reason)
    end
  end

  ## Guest-authenticated single-task endpoints

  def get_task(conn) do
    with_guest(conn,
      allow_query_token?: false,
      fun: fn %{collaborator: collab, workspace: ws} ->
        limit = parse_limit(conn.query_params["limit"], 100)
        before = blank_to_nil(conn.query_params["before"])

        page_opts =
          [limit: limit]
          |> then(&if(before, do: Keyword.put(&1, :before, before), else: &1))

        with {:ok, task} <-
               Comma.Salix.Client.impl().get_group_conversation(ws, collab.conversation_id),
             {:ok, page} <-
               Comma.Salix.Client.impl().list_group_conversation_message_page(
                 ws,
                 collab.conversation_id,
                 page_opts
               ) do
          senders = CollaborationGuests.message_sender_directory(collab)
          projected = project_guest_messages(page["messages"] || [], collab, senders)
          has_older = page["has_older"] == true

          next_cursor =
            case {has_older, get_in(page, ["covered", "first_seq"])} do
              {true, seq} when is_integer(seq) and seq > 1 -> Integer.to_string(seq)
              _ -> nil
            end

          send_public_json(conn, 200, %{
            "guest" => %{
              "email" => collab.invited_email,
              "name" => blank_to_nil(collab.guest_name)
            },
            "task" => %{
              "group_id" => collab.group_id,
              "conversation_id" => collab.conversation_id,
              "title" => blank_to_nil(collab.title) || task["title"] || "Shared Task",
              "status" => task["status"] || "active",
              "host_name" => CollaborationGuests.host_display_name(collab.host_user_id),
              "members" => CollaborationGuests.task_members_for_guest(collab)
            },
            "messages" => projected,
            "has_older" => has_older,
            "next_cursor" => next_cursor
          })
        else
          {:error, {:bad_request, message}} ->
            send_public_json(conn, 400, %{"error" => message})

          {:error, :not_found} ->
            send_public_json(conn, 404, %{"error" => "not_found"})

          {:error, _reason} ->
            send_public_json(conn, 503, %{"error" => "temporarily_unavailable"})
        end
      end
    )
  end

  def post_message(conn) do
    with_guest(conn,
      allow_query_token?: false,
      fun: fn %{collaborator: collab, workspace: ws} ->
        params = body(conn)
        text = params["text"]
        mention_comma = params["mention_comma"] == true

        trimmed = if is_binary(text), do: String.trim(text), else: ""

        cond do
          trimmed == "" ->
            send_public_json(conn, 400, %{"error" => "text is required"})

          byte_size(trimmed) > @content_bytes ->
            send_public_json(conn, 400, %{"error" => "text is too long"})

          true ->
            display_name = CollaborationGuests.sender_display_name(collab)
            request_id = blank_to_nil(params["client_request_id"]) || new_request_id()

            metadata =
              %{"guest_collaborator_id" => collab.id}
              |> then(&if(display_name, do: Map.put(&1, "author_name", display_name), else: &1))
              |> then(&if(mention_comma, do: Map.put(&1, "mention_comma", true), else: &1))

            guest_user_id = "guest:" <> collab.id

            attrs =
              %{
                "actor_type" => "user",
                "user_id" => guest_user_id,
                "content" => [%{"type" => "text", "text" => trimmed}],
                "client_request_id" => request_id,
                "metadata" => metadata
              }
              |> then(&if(display_name, do: Map.put(&1, "author_name", display_name), else: &1))

            with {:ok, _participant} <-
                   Comma.Salix.Client.impl().ensure_group_conversation_user_participant(
                     ws,
                     collab.conversation_id,
                     guest_user_id
                   ),
                 {:ok, result} <-
                   Comma.Salix.Client.impl().append_group_conversation_message(
                     ws,
                     collab.conversation_id,
                     attrs
                   ) do
              raw_message =
                with message_id when is_binary(message_id) <- result["message_id"],
                     {:ok, stored} <-
                       Comma.Salix.Client.impl().get_group_conversation_message(
                         ws,
                         collab.conversation_id,
                         message_id
                       ) do
                  stored
                else
                  _ -> result["message"] || result
                end

              senders = CollaborationGuests.message_sender_directory(collab)

              projected =
                project_guest_message(raw_message, collab, senders) ||
                  %{
                    "id" => result["message_id"] || request_id,
                    "role" => "user",
                    "sender_name" => display_name,
                    "is_guest" => true,
                    "is_self" => true,
                    "created_at" => raw_message["created_at"],
                    "content" => [%{"type" => "text", "text" => trimmed}]
                  }

              send_public_json(conn, 201, %{"message" => projected})
            else
              {:error, :not_found} ->
                send_public_json(conn, 404, %{"error" => "not_found"})

              {:error, {:bad_request, message}} ->
                send_public_json(conn, 400, %{"error" => message})

              {:error, _reason} ->
                send_public_json(conn, 503, %{"error" => "temporarily_unavailable"})
            end
        end
      end
    )
  end

  def events(conn) do
    with_guest(conn,
      allow_query_token?: true,
      fun: fn %{collaborator: collab, workspace: ws} ->
        # Subscribe to revocation BEFORE subscribing to task events so a concurrent
        # removal is never missed.
        :ok = CollaborationGuests.subscribe(collab.id)

        with {:ok, _still_valid} <- CollaborationGuests.authenticate(extract_token(conn, true)),
             {:ok, subscription} <-
               Comma.Salix.Client.impl().subscribe_group_conversation_list(
                 ws,
                 "agent_task",
                 SystemsRuntime.Proc.self()
               ) do
          wait_ms = sse_wait_ms(conn.query_params["wait"])
          stream_guest_sse(conn, collab, subscription, wait_ms)
        else
          {:error, :guest_session_revoked} ->
            send_public_json(conn, 401, %{"error" => "guest_session_revoked"})

          {:error, _reason} ->
            send_public_json(conn, 503, %{"error" => "temporarily_unavailable"})
        end
      end
    )
  end

  def list_files(conn) do
    with_guest(conn,
      allow_query_token?: false,
      fun: fn %{collaborator: collab, workspace: ws} ->
        case Comma.Salix.Client.impl().list_task_folder(ws, collab.conversation_id) do
          {:ok, files} ->
            used_bytes = Enum.reduce(files, 0, fn f, acc -> acc + (f["size"] || 0) end)

            send_public_json(conn, 200, %{
              "entries" => files,
              "used_bytes" => used_bytes
            })

          {:error, :not_found} ->
            send_public_json(conn, 404, %{"error" => "not_found"})

          {:error, _reason} ->
            send_public_json(conn, 503, %{"error" => "temporarily_unavailable"})
        end
      end
    )
  end

  def upload_file(conn) do
    with_guest(conn,
      allow_query_token?: false,
      fun: fn %{collaborator: collab, workspace: ws} ->
        with {:ok, name, body, conn} <- extract_upload(conn),
             true <- byte_size(body) > 0 || {:error, :file_required},
             {:ok, file} <-
               Comma.Salix.Client.impl().write_task_file(ws, collab.conversation_id, name, body) do
          send_public_json(conn, 201, file)
        else
          {:error, :file_too_large} ->
            send_public_json(conn, 413, %{"error" => "file_too_large"})

          {:error, :file_required} ->
            send_public_json(conn, 400, %{"error" => "file_required"})

          {:error, {:bad_request, message}} ->
            send_public_json(conn, 400, %{"error" => message})

          {:error, :not_found} ->
            send_public_json(conn, 404, %{"error" => "not_found"})

          {:error, _reason} ->
            send_public_json(conn, 503, %{"error" => "temporarily_unavailable"})
        end
      end
    )
  end

  def download_file(conn) do
    with_guest(conn,
      allow_query_token?: true,
      fun: fn %{collaborator: collab, workspace: ws} ->
        path = conn.query_params["path"] || ""

        with {:ok, file} <-
               Comma.Salix.Client.impl().open_task_file(ws, collab.conversation_id, path),
             {:ok, conn} <-
               conn
               |> put_public_headers()
               |> CommaWeb.TaskFileDownload.send(file) do
          conn
        else
          {:error, :not_found} ->
            send_public_json(conn, 404, %{"error" => "not_found"})

          {:error, _reason} ->
            send_public_json(conn, 503, %{"error" => "temporarily_unavailable"})
        end
      end
    )
  end

  def leave(conn) do
    with_guest(conn,
      allow_query_token?: false,
      fun: fn auth ->
        case CollaborationGuests.leave(auth) do
          {:ok, row} ->
            with {:error, reason} <- CommaWeb.CollaborationNotice.member_changed(row) do
              Logger.warning(
                "collaboration guest leave notice not queued reason=#{inspect(reason)}"
              )
            end

            send_public_json(conn, 200, %{"ok" => true})

          {:error, :guest_session_revoked} ->
            send_public_json(conn, 401, %{"error" => "guest_session_revoked"})
        end
      end
    )
  end

  ## Internal helpers

  defp with_guest(conn, opts) do
    allow_query? = Keyword.get(opts, :allow_query_token?, false)
    fun = Keyword.fetch!(opts, :fun)

    case CollaborationGuests.authenticate(extract_token(conn, allow_query?)) do
      {:ok, auth} ->
        fun.(auth)

      {:error, :guest_session_revoked} ->
        send_public_json(conn, 401, %{"error" => "guest_session_revoked"})

      {:error, _reason} ->
        send_public_json(conn, 401, %{"error" => "unauthorized"})
    end
  end

  defp extract_token(conn, allow_query?) do
    bearer =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> blank_to_nil(token)
        _ -> nil
      end

    bearer || if(allow_query?, do: blank_to_nil(conn.query_params["token"]))
  end

  defp extract_upload(conn) do
    case conn.body_params do
      %{"file" => %Plug.Upload{path: tmp_path, filename: filename}} ->
        case File.read(tmp_path) do
          {:ok, body} when byte_size(body) <= @task_file_max_bytes ->
            {:ok, filename || conn.query_params["name"] || "file", body, conn}

          {:ok, _body} ->
            {:error, :file_too_large}

          {:error, _} ->
            {:error, :upload_incomplete}
        end

      _ ->
        case Plug.Conn.read_body(conn,
               length: @task_file_max_bytes + 1,
               read_length: 1_048_576,
               read_timeout: 60_000
             ) do
          {:ok, body, conn} when byte_size(body) <= @task_file_max_bytes ->
            {:ok, conn.query_params["name"] || "file", body, conn}

          {:ok, _body, _conn} ->
            {:error, :file_too_large}

          {:more, _partial, _conn} ->
            {:error, :file_too_large}

          {:error, _reason} ->
            {:error, :upload_incomplete}
        end
    end
  end

  defp stream_guest_sse(conn, collab, subscription, wait_ms) do
    owner_ref =
      case subscription["owner_pid"] do
        pid when SystemsRuntime.Proc.is_process(pid) -> SystemsRuntime.Proc.monitor(pid)
        _ -> nil
      end

    conn =
      conn
      |> put_public_headers()
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    resync = %{
      "type" => "task_resync_required",
      "group_id" => collab.group_id,
      "conversation_id" => collab.conversation_id,
      "version" => subscription["version"] || "0"
    }

    case chunk_sse(conn, "resync", resync) do
      {:ok, conn} ->
        now_ms = SystemsClock.monotonic_time(:millisecond)
        deadline_ms = if wait_ms == :infinity, do: nil, else: now_ms + wait_ms
        guest_sse_loop(conn, collab, owner_ref, deadline_ms, now_ms + @sse_heartbeat_ms)

      _ ->
        conn
    end
  end

  defp guest_sse_loop(conn, collab, owner_ref, deadline_ms, heartbeat_at_ms) do
    now_ms = SystemsClock.monotonic_time(:millisecond)

    cond do
      is_integer(deadline_ms) and now_ms >= deadline_ms ->
        conn

      now_ms >= heartbeat_at_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            guest_sse_loop(conn, collab, owner_ref, deadline_ms, now_ms + @sse_heartbeat_ms)

          _ ->
            conn
        end

      true ->
        timeout =
          if is_integer(deadline_ms),
            do: min(deadline_ms - now_ms, heartbeat_at_ms - now_ms),
            else: heartbeat_at_ms - now_ms

        SystemsClock.vreceive do
          :guest_revoked ->
            _ = chunk_sse(conn, "revoked", %{"reason" => "removed"})
            conn

          {:group_conversation_list_invalidated, group_id, "agent_task", conversation_id, version} ->
            if group_id == collab.group_id and conversation_id == collab.conversation_id do
              case chunk_sse(conn, "task_updated", %{
                     "group_id" => group_id,
                     "conversation_id" => conversation_id,
                     "version" => version
                   }) do
                {:ok, conn} ->
                  guest_sse_loop(conn, collab, owner_ref, deadline_ms, heartbeat_at_ms)

                _ ->
                  conn
              end
            else
              guest_sse_loop(conn, collab, owner_ref, deadline_ms, heartbeat_at_ms)
            end

          {:DOWN, ^owner_ref, :process, _pid, _reason} when not is_nil(owner_ref) ->
            conn
        after
          max(timeout, 0) ->
            guest_sse_loop(conn, collab, owner_ref, deadline_ms, heartbeat_at_ms)
        end
    end
  end

  defp chunk_sse(conn, event, data) do
    chunk(conn, "event: #{event}\ndata: #{Jason.encode!(data)}\n\n")
  end

  defp sse_wait_ms(nil), do: :infinity
  defp sse_wait_ms(""), do: :infinity
  defp sse_wait_ms("infinity"), do: :infinity

  defp sse_wait_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {ms, ""} when ms >= 0 -> min(ms, @max_sse_wait_ms)
      _ -> :infinity
    end
  end

  defp sse_wait_ms(_), do: :infinity

  defp invite_error(conn, :not_found),
    do: send_public_json(conn, 404, %{"error" => "not_found"})

  defp invite_error(conn, :invite_expired),
    do:
      send_public_json(conn, 410, %{
        "error" => "invite_expired",
        "message" => "This invite link has expired."
      })

  defp invite_error(conn, :email_mismatch),
    do: send_public_json(conn, 403, %{"error" => "email_mismatch"})

  defp invite_error(conn, :invalid_email),
    do: send_public_json(conn, 400, %{"error" => "invalid_email"})

  defp invite_error(conn, _reason),
    do: send_public_json(conn, 503, %{"error" => "temporarily_unavailable"})

  defp send_public_json(conn, status, body) do
    conn
    |> put_public_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp put_public_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex")
  end

  defp body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> %{}
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp remote_ip(%Plug.Conn{remote_ip: ip}) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp remote_ip(_), do: "unknown"

  defp parse_limit(nil, default), do: default

  defp parse_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 -> min(n, 200)
      _ -> default
    end
  end

  defp parse_limit(_, default), do: default

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  ## Guest-safe message projection

  @comma_context_marker "[[comma-context]]"
  @comma_protocol_marker "[[comma-protocol]]"
  @comma_fence_pattern ~r/```comma:[\s\S]*?(?:```|$)/u

  @doc false
  def project_guest_messages(messages, collab, senders) when is_list(messages) do
    Enum.flat_map(messages, fn msg ->
      case project_guest_message(msg, collab, senders) do
        nil -> []
        projected -> [projected]
      end
    end)
  end

  def project_guest_messages(_messages, _collab, _senders), do: []

  defp project_guest_message(msg, collab, senders) when is_map(msg) do
    actor_type = msg["actor_type"]

    cond do
      # System messages (`agent_input`, watch nudges, internal app_events,
      # member change events) are never exposed to external guests.
      actor_type == "system" or msg["agent_input"] != nil ->
        nil

      msg["kind"] == "app_event" ->
        nil

      true ->
        raw_content = msg["content"]

        cond do
          milestone_only?(actor_type, raw_content) ->
            nil

          comma_context_message?(raw_content) ->
            nil

          true ->
            blocks = project_guest_blocks(raw_content)

            if blocks == [] do
              nil
            else
              {role, sender_name, is_guest, is_self} =
                resolve_guest_sender(msg, collab, senders)

              id = blank_to_nil(msg["message_id"]) || blank_to_nil(msg["id"])

              %{
                "id" => id,
                "role" => role,
                "sender_name" => sender_name,
                "is_guest" => is_guest,
                "is_self" => is_self,
                "created_at" => msg["created_at"],
                "content" => blocks
              }
              |> maybe_put_seq(msg["seq"])
            end
        end
    end
  end

  defp project_guest_message(_msg, _collab, _senders), do: nil

  defp resolve_guest_sender(%{"actor_type" => "agent"}, _collab, _senders) do
    {"assistant", "Comma", false, false}
  end

  defp resolve_guest_sender(msg, collab, senders) do
    user_id = blank_to_nil(msg["user_id"])
    self_user_id = "guest:" <> collab.id
    is_self = user_id == self_user_id
    is_guest = is_binary(user_id) and String.starts_with?(user_id, "guest:")

    sender_name =
      case Map.get(senders, user_id) do
        %{name: name} ->
          name

        nil ->
          if is_guest do
            blank_to_nil(get_in(msg, ["metadata", "author_name"]))
          else
            if user_id == collab.host_user_id, do: "Host", else: "Member"
          end
      end

    {"user", sender_name, is_guest, is_self}
  end

  defp milestone_only?("agent", blocks) when is_list(blocks) and blocks != [] do
    Enum.all?(blocks, fn
      %{"type" => "milestone"} -> true
      _ -> false
    end)
  end

  defp milestone_only?(_actor_type, _blocks), do: false

  defp comma_context_message?(text) when is_binary(text) do
    String.starts_with?(String.trim_leading(text), @comma_context_marker)
  end

  defp comma_context_message?(blocks) when is_list(blocks) do
    joined =
      blocks
      |> Enum.flat_map(fn
        %{"type" => type, "text" => text} when type in ["text", "markdown"] and is_binary(text) ->
          [text]

        _ ->
          []
      end)
      |> Enum.join("\n")

    String.starts_with?(String.trim_leading(joined), @comma_context_marker)
  end

  defp comma_context_message?(_content), do: false

  defp project_guest_blocks(text) when is_binary(text) do
    case sanitize_guest_text(text) do
      "" -> []
      cleaned -> [%{"type" => "text", "text" => cleaned}]
    end
  end

  defp project_guest_blocks(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, &project_guest_block/1)
  end

  defp project_guest_blocks(_content), do: []

  defp project_guest_block(%{"type" => type, "text" => text})
       when type in ["text", "markdown"] and is_binary(text) do
    case sanitize_guest_text(text) do
      "" -> []
      cleaned -> [%{"type" => "text", "text" => cleaned}]
    end
  end

  defp project_guest_block(%{"type" => type} = block) when type in ["file", "image"] do
    raw_path =
      blank_to_nil(block["path"]) ||
        blank_to_nil(get_in(block, ["file_ref", "path"]))

    safe_path = if safe_task_path?(raw_path), do: raw_path, else: nil

    file_name =
      blank_to_nil(block["file_name"]) ||
        blank_to_nil(block["fileName"]) ||
        if(is_binary(safe_path), do: Path.basename(safe_path))

    if is_binary(file_name) do
      size =
        case block["size"] || get_in(block, ["blob_ref", "size"]) do
          n when is_integer(n) and n >= 0 -> n
          _ -> nil
        end

      mime_type =
        blank_to_nil(block["mime_type"]) ||
          blank_to_nil(block["mimeType"]) ||
          blank_to_nil(block["media_type"]) ||
          blank_to_nil(get_in(block, ["blob_ref", "content_type"]))

      projected =
        %{"type" => type, "file_name" => file_name}
        |> maybe_put("path", safe_path)
        |> maybe_put("size", size)
        |> maybe_put("mime_type", mime_type)

      [projected]
    else
      []
    end
  end

  defp project_guest_block(%{"type" => type} = block) when type in ["mini_app", "mini-app"] do
    app_id = blank_to_nil(block["app_id"]) || blank_to_nil(block["appId"])

    if is_binary(app_id) do
      # Salix mini_app blocks carry schema `"version" => 1` alongside
      # `"app_version" => N`; prefer `app_version` so guests see the real version.
      app_version =
        positive_int(block["app_version"] || block["appVersion"] || block["version"])

      projected =
        %{
          "type" => "mini_app",
          "app_id" => app_id,
          "name" => blank_to_nil(block["name"]) || "Mini App",
          "summary" => if(is_binary(block["summary"]), do: block["summary"], else: "")
        }
        |> maybe_put("version", app_version)

      [projected]
    else
      []
    end
  end

  defp project_guest_block(_block), do: []

  defp sanitize_guest_text(text) do
    text
    |> String.split(@comma_protocol_marker, parts: 2)
    |> hd()
    |> String.replace(@comma_fence_pattern, "")
    |> String.trim()
  end

  defp safe_task_path?(path) when is_binary(path) do
    String.starts_with?(path, "/task/") and
      not String.contains?(path, ["\\", <<0>>]) and
      not Enum.member?(String.split(path, "/"), "..")
  end

  defp safe_task_path?(_), do: false

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_seq(map, seq) when is_integer(seq) and seq > 0, do: Map.put(map, "seq", seq)
  defp maybe_put_seq(map, _seq), do: map

  defp new_request_id,
    do: "cgs_msg_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(12), padding: false)
end
