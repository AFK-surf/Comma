defmodule SalixIM.PhotonIMessage do
  @moduledoc """
  Narrow Req adapter for the Photon v2 REST API, the second
  transport of Comma iMessage. It targets shared-pool (Free and Pro) lines:
  each person gets a line assignment, and a line sends only in a direct Space
  to a peer that has messaged it since its assignment.

  Photon publishes OpenAPI clients for TypeScript, Python, Go and Rust, but no
  Elixir client. This module covers only the calls Comma uses.
  Redirects and automatic retries are disabled. The bearer belongs to one
  configured origin, and an ambiguous send is not evidence that nothing was sent.
  A `202` is Photon acceptance, not Apple delivery. No cross-call deduplication
  is claimed.
  """

  @base_url "https://api.photon.codes"
  @max_image_bytes 20 * 1024 * 1024
  @request_timeout_ms 15_000
  @webhook_tolerance_seconds 300
  @assignment_pages 5
  @list_page_size 100

  def config, do: SystemsRuntime.get_env(:salix_im, :imessage_photon, [])

  def configured? do
    config()[:enabled] == true and
      Enum.all?([:project_id, :api_key, :webhook_secret], fn key ->
        is_binary(config()[key]) and String.trim(config()[key]) != ""
      end)
  end

  def project_id, do: config()[:project_id]
  # Receiver progress and connect records are keyed by the Photon project.
  def relay_id, do: "photon:" <> (project_id() || "")
  def identity, do: config()[:identity] || "Comma"

  @doc """
  Normalizes an iMessage handle as Photon matches it: E.164 for a phone
  number, lowercase for an email address. Returns `nil` for anything else.
  """
  def normalize_handle(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.contains?(trimmed, "@") do
      email = String.downcase(trimmed)
      if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[a-z]{2,}$/, email), do: email
    else
      phone = String.replace(trimmed, ~r/[\s().-]/, "")
      if Regex.match?(~r/^\+[1-9]\d{6,14}$/, phone), do: phone
    end
  end

  def normalize_handle(_value), do: nil

  # ---- webhook ----

  @doc """
  Verifies Photon v2 Standard Webhooks over the unmodified body and delivery
  ID. The destination secret is base64 after `whsec_`; `webhook-signature`
  contains space-separated `v1,<base64 HMAC-SHA256>` signatures for rotation.
  The timestamp must be within five minutes.
  """
  def verify_webhook(raw_body, id, timestamp, signatures)
      when is_binary(raw_body) and is_binary(id) and id != "" and
             is_binary(timestamp) and is_binary(signatures) do
    with "whsec_" <> encoded <- config()[:webhook_secret],
         {:ok, key} when byte_size(key) > 0 <- Base.decode64(encoded),
         {seconds, ""} <- Integer.parse(timestamp),
         true <-
           abs(DateTime.to_unix(SystemsClock.utc_now()) - seconds) <= @webhook_tolerance_seconds do
      expected =
        :crypto.mac(:hmac, :sha256, key, id <> "." <> timestamp <> "." <> raw_body)
        |> Base.encode64()

      valid? =
        signatures
        |> String.split()
        |> Enum.any?(fn
          "v1," <> signature -> Plug.Crypto.secure_compare(expected, signature)
          _ -> false
        end)

      if valid?, do: :ok, else: {:error, :unauthorized}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def verify_webhook(_raw_body, _id, _timestamp, _signatures), do: {:error, :unauthorized}

  # ---- binding setup ----

  @doc "Registers the handle as a project User. Shared lines message only project Users."
  def register_user(handle) do
    case request(:post, "/users", json: %{"platform" => "imessage", "handle" => handle}) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, _body} -> {:error, :imessage_unavailable}
      error -> error
    end
  end

  @doc """
  Assigns a pooled shared line to the handle and returns the line number.
  An existing assignment for the handle is reused.
  """
  def assign_line(handle) do
    case request(:post, "/platforms/imessage/assignments",
           json: %{"handle" => handle},
           headers: [{"idempotency-key", idempotency_key("assign")}]
         ) do
      {:ok, assignment} ->
        assignment_result(assignment)

      {:error, {:photon, 409, %{"code" => "ASSIGNMENT_EXISTS"}}} ->
        find_assignment(handle, nil, @assignment_pages)

      {:error, {:photon, 409, %{"code" => "SHARED_LINE_CAP_EXCEEDED"}}} ->
        {:error, :imessage_capacity_reached}

      {:error, {:photon, 503, %{"code" => "SHARED_LINE_POOL_EXHAUSTED"}}} ->
        {:error, :imessage_capacity_reached}

      error ->
        error
    end
  end

  @doc "Lists active assignments, at most `pages` pages of 200."
  def list_assignments(pages \\ @assignment_pages), do: list_assignments(nil, pages, [])

  defp list_assignments(_token, 0, acc), do: {:ok, acc}

  defp list_assignments(token, pages, acc) do
    params = [pageSize: 200] ++ if(token, do: [pageToken: token], else: [])

    case request(:get, "/platforms/imessage/assignments", params: params) do
      {:ok, %{"assignments" => items} = page} when is_list(items) ->
        acc = acc ++ Enum.filter(items, &is_map/1)

        case page["nextPageToken"] do
          next when is_binary(next) and next != "" -> list_assignments(next, pages - 1, acc)
          _ -> {:ok, acc}
        end

      {:ok, _body} ->
        {:error, :imessage_unavailable}

      error ->
        error
    end
  end

  defp find_assignment(handle, _token, pages) do
    with {:ok, assignments} <- list_assignments(pages) do
      assignments
      |> Enum.find(&(normalize_handle(&1["handle"]) == handle and is_nil(&1["releasedAt"])))
      |> case do
        nil -> {:error, :imessage_unavailable}
        assignment -> assignment_result(assignment)
      end
    end
  end

  defp assignment_result(%{"assignmentId" => id, "assignedPhoneNumber" => line})
       when is_binary(id) and id != "" and is_binary(line) and line != "",
       do: {:ok, %{"assignment_id" => id, "line_handle" => line}}

  defp assignment_result(_assignment), do: {:error, :imessage_unavailable}

  @doc "Releases a line assignment. A missing assignment is already released."
  def release_assignment(assignment_id) when is_binary(assignment_id) and assignment_id != "" do
    case request(:delete, "/platforms/imessage/assignments/#{URI.encode_www_form(assignment_id)}") do
      {:ok, _} -> :ok
      {:error, {:photon, 404, _}} -> :ok
      error -> error
    end
  end

  def release_assignment(_assignment_id), do: :ok

  # ---- receive ----

  @doc """
  Lists received iMessage Messages created at or after `since`, oldest first.
  Photon lists are eventually consistent, so callers re-read an overlap window.
  """
  def list_received(%DateTime{} = since, page_token \\ nil) do
    params =
      [
        platform: "imessage",
        direction: "received",
        createdSince: DateTime.to_iso8601(since),
        orderBy: "created_at",
        order: "asc",
        pageSize: @list_page_size
      ] ++ if(page_token, do: [pageToken: page_token], else: [])

    case request(:get, "/messages", params: params) do
      {:ok, %{"items" => items} = page} when is_list(items) ->
        {:ok, Enum.filter(items, &is_map/1), page["nextPageToken"]}

      {:ok, _body} ->
        {:error, :imessage_unavailable}

      error ->
        error
    end
  end

  @doc """
  Maps one received Photon Message to the transport-neutral iMessage event
  that `CommaWeb.IMessageIntegration.handle_event/1` handles.
  Read receipts, typing and other content without text or attachments map to `:ignore`.
  """
  def to_event(%{"id" => id, "sentBy" => sent_by, "space" => space, "content" => content} = msg)
      when is_binary(id) and is_map(sent_by) and is_map(space) and is_map(content) do
    participants = List.wrap(space["participantIds"])

    agent_user_id =
      get_in(msg, ["receivedBy", "id"]) || Enum.find(participants, &(&1 != sent_by["id"]))

    {text, attachments} = content_parts(content)

    if (text in [nil, ""] and attachments == []) or msg["status"] not in [nil, "received"] do
      :ignore
    else
      {:ok,
       %{
         "event_id" => id,
         "type" => "message",
         "transport" => "photon",
         "message" => %{
           "message_id" => id,
           "sender_handle" => normalize_handle(sent_by["handle"]) || "",
           "chat_guid" => space["id"],
           "agent_user_id" => agent_user_id,
           "is_group" => length(participants) != 2,
           "text" => text,
           "attachments" => attachments,
           "reply_to_message_id" => msg["parentMessageId"]
         }
       }}
    end
  end

  def to_event(_message), do: :ignore

  defp content_parts(%{"type" => "text", "text" => text}) when is_binary(text), do: {text, []}

  defp content_parts(%{"type" => "attachment", "attachmentId" => id})
       when is_binary(id) and id != "",
       do: {nil, [%{"attachment_id" => id}]}

  defp content_parts(%{"type" => "group", "parts" => parts}) when is_list(parts) do
    parts = Enum.map(parts, &content_parts/1)
    texts = parts |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 in [nil, ""]))
    text = if texts == [], do: nil, else: Enum.join(texts, "\n")
    {text, Enum.flat_map(parts, &elem(&1, 1))}
  end

  defp content_parts(_content), do: {nil, []}

  @doc "Reads attachment metadata: content type, file name and size."
  def get_attachment(attachment_id) when is_binary(attachment_id) and attachment_id != "" do
    case request(:get, "/attachments/#{URI.encode_www_form(attachment_id)}") do
      {:ok, %{"contentType" => type} = attachment} when is_binary(type) ->
        {:ok,
         %{
           "attachment_id" => attachment_id,
           "content_type" => type,
           "name" => attachment["filename"],
           "size" => attachment["sizeBytes"]
         }}

      {:ok, _body} ->
        {:error, :imessage_image_unavailable}

      error ->
        error
    end
  end

  def get_attachment(_attachment_id), do: {:error, :imessage_image_unavailable}

  def download_image(agent_id, attachment_id)
      when is_binary(attachment_id) and attachment_id != "" do
    alias SalixStore.Blob
    state_key = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    Process.put(state_key, Blob.put_stream_init(agent_id))

    try do
      with :ok <- require_configured() do
        response =
          Req.get(url("/attachments/#{URI.encode_www_form(attachment_id)}/content"),
            headers: headers(),
            retry: false,
            redirect: false,
            decode_body: false,
            receive_timeout: SystemsClock.timeout(@request_timeout_ms),
            plug: req_options()[:plug],
            into: fn {:data, chunk}, {req, resp} ->
              size = (resp.private[:photon_bytes] || 0) + byte_size(chunk)

              if resp.status == 200 and size <= @max_image_bytes do
                case Blob.put_stream_step(Process.get(state_key), chunk) do
                  {:ok, state} ->
                    Process.put(state_key, state)
                    {:cont, {req, Req.Response.put_private(resp, :photon_bytes, size)}}

                  {:error, _, state} ->
                    Process.put(state_key, state)
                    {:halt, {req, Req.Response.put_private(resp, :photon_error, true)}}
                end
              else
                {:halt, {req, Req.Response.put_private(resp, :photon_error, true)}}
              end
            end
          )

        case response do
          {:ok, %{status: 200, private: private}} when not is_map_key(private, :photon_error) ->
            with {:ok, ref} <- Blob.put_stream_finish(Process.get(state_key)) do
              Process.delete(state_key)
              {:ok, %{ref: ref, size: private[:photon_bytes] || 0}}
            end

          _ ->
            {:error, :imessage_image_unavailable}
        end
      end
    after
      if state = Process.get(state_key), do: Blob.put_stream_abort(state)
      Process.delete(state_key)
    end
  end

  def download_image(_agent_id, _attachment_id), do: {:error, :imessage_image_unavailable}

  # ---- send ----

  @doc "Sends text with an optional parent. An explicit unsupported-reply refusal permits one ordinary send."
  def send_text(sender_id, space_id, text, parent_id \\ nil) do
    send_content(
      sender_id,
      space_id,
      %{"type" => "text", "format" => "plain", "text" => text},
      parent_id
    )
  end

  @doc "Adds or removes a tapback (`❤️ 👍 👎 😂 ‼️ ❓`) or emoji reaction on `parent_id`."
  def send_reaction(sender_id, space_id, parent_id, emoji, action)
      when action in ["add", "remove"] do
    send_content(
      sender_id,
      space_id,
      %{"type" => "reaction", "reaction" => emoji, "action" => action},
      parent_id
    )
  end

  @doc "Reads one Message, for a reply or quote target."
  def get_message(message_id) when is_binary(message_id) and message_id != "" do
    case request(:get, "/messages/#{URI.encode_www_form(message_id)}") do
      {:ok, %{"id" => id} = message} when is_binary(id) -> {:ok, message}
      {:ok, _body} -> {:error, :imessage_unavailable}
      error -> error
    end
  end

  def get_message(_message_id), do: {:error, {:photon, 404, %{"code" => "MESSAGE_NOT_FOUND"}}}

  @doc """
  Starts (`true`) or stops (`false`) the line's typing indicator in a Space.
  Photon answers 202 and does not refresh it: the caller repeats `true`.
  The request waits at most 2 seconds, because typing is presentation only.
  """
  def set_typing(sender_id, space_id, typing?) when is_boolean(typing?) do
    case request(:post, "/spaces/#{URI.encode_www_form(space_id)}/typing",
           json: %{"senderId" => sender_id, "typing" => typing?},
           receive_timeout: SystemsClock.timeout(2_000),
           connect_options: [timeout: 2_000]
         ) do
      {:ok, _message} -> :ok
      error -> error
    end
  end

  @doc """
  Uploads the image, then sends it. Photon accepts attachment captions only on
  Telegram, so a caption follows as a separate text Message.
  An upload failure sends nothing. After the image send, a caption failure is
  reported as unknown delivery.
  """
  def send_image(sender_id, space_id, upload, caption \\ "", parent_id \\ nil) do
    if byte_size(upload.data) > @max_image_bytes do
      {:error, :imessage_image_too_large}
    else
      with {:ok, attachment_id} <- upload_attachment(upload),
           {:ok, sent} <-
             send_content(
               sender_id,
               space_id,
               %{"type" => "attachment", "attachmentId" => attachment_id},
               parent_id
             ) do
        if is_binary(caption) and String.trim(caption) != "" do
          case send_text(sender_id, space_id, caption) do
            {:ok, caption_sent} ->
              {:ok, Map.merge(caption_sent, Map.take(sent, ["reply_fallback"]))}

            _ ->
              # The image was accepted. Do not describe the whole operation as not sent.
              SalixIM.IMessageRelay.delivery_unknown()
          end
        else
          {:ok, sent}
        end
      end
    end
  end

  defp upload_attachment(upload) do
    content_type = MIME.from_path(upload.filename || "image")
    boundary = Base.encode16(SystemsRuntime.Proc.random_bytes(16), case: :lower)

    meta =
      Jason.encode!(%{
        "contentType" => content_type,
        "sizeBytes" => byte_size(upload.data),
        "filename" => Path.basename(upload.filename || "image")
      })

    body =
      IO.iodata_to_binary([
        "--#{boundary}\r\ncontent-type: application/json\r\n\r\n",
        meta,
        "\r\n--#{boundary}\r\ncontent-type: #{content_type}\r\n\r\n",
        upload.data,
        "\r\n--#{boundary}--\r\n"
      ])

    case request(:post, "/attachments",
           body: body,
           headers: [
             {"content-type", "multipart/related; boundary=#{boundary}"},
             {"idempotency-key", idempotency_key("upload")}
           ]
         ) do
      {:ok, %{"id" => id}} when is_binary(id) and id != "" -> {:ok, id}
      {:error, {:photon, 413, _}} -> {:error, :imessage_image_too_large}
      _ -> {:error, :imessage_image_unavailable}
    end
  end

  defp send_content(sender_id, space_id, content, parent_id) do
    body = %{"spaceId" => space_id, "senderId" => sender_id, "content" => content}
    body = if parent_id, do: Map.put(body, "parentMessageId", parent_id), else: body

    result =
      request(:post, "/messages",
        json: body,
        headers: [{"idempotency-key", idempotency_key("send")}]
      )

    # This observed v2 refusal is narrower than SPACE_NOT_SENDABLE alone.
    # It proves that the first send was rejected. Never downgrade an ambiguous send.
    case result do
      {:error,
       {:photon, 409,
        %{"code" => "SPACE_NOT_SENDABLE", "detail" => "Replies are not supported for this Space"} =
            problem}}
      when is_binary(parent_id) ->
        case content["type"] do
          type when type in ["text", "attachment"] ->
            with {:ok, message} <- send_content(sender_id, space_id, content, nil) do
              {:ok, Map.put(message, "reply_fallback", "ordinary_message")}
            end

          "reaction" ->
            rejected(
              "imessage_reaction_unsupported",
              "Photon does not support reactions in this chat. Nothing was sent. " <>
                "Do not retry the reaction or reconnect. You can send an ordinary text answer.",
              problem
            )
        end

      _ ->
        sent(result)
    end
  end

  # A clear 4xx means Photon refused the request before acceptance.
  defp sent({:ok, %{"id" => id} = message}) when is_binary(id) and id != "",
    do: {:ok, Map.put(message, "message_id", id)}

  defp sent({:error, :imessage_unavailable} = error), do: error

  defp sent({:error, {:photon, status, problem}}) when status in 400..499 and status != 408 do
    rejected(
      "imessage_send_rejected",
      "Photon refused this iMessage send (#{problem["code"] || status}). Nothing was sent. " <>
        "Do not retry the same send. Check the provider reason before changing the connection.",
      problem
    )
  end

  defp sent(_), do: SalixIM.IMessageRelay.delivery_unknown()

  defp rejected(code, message, problem) do
    {:error,
     %{
       "code" => code,
       "delivery_status" => "not_sent",
       "retryable" => false,
       "message" => message,
       "provider_code" => problem["code"],
       "provider_detail" => problem["detail"],
       "provider_request_id" => problem["requestId"]
     }
     |> Map.reject(fn {_key, value} -> is_nil(value) end)}
  end

  # ---- HTTP ----

  defp request(method, path, opts \\ []) do
    observe("imessage_photon_request", fn -> do_request(method, path, opts) end)
  end

  defp do_request(method, path, opts) do
    with :ok <- require_configured() do
      {extra_headers, opts} = Keyword.pop(opts, :headers, [])

      options =
        Keyword.merge(
          [
            method: method,
            url: url(path),
            headers: headers() ++ extra_headers,
            retry: false,
            redirect: false,
            decode_body: false,
            receive_timeout: SystemsClock.timeout(@request_timeout_ms),
            connect_options: [timeout: 5_000]
          ],
          Keyword.merge(req_options(), opts)
        )

      response =
        case SystemsClock.run_bounded(fn -> Req.request(options) end, @request_timeout_ms) do
          {:ok, response} -> response
          _exit_or_timeout -> {:error, :timeout}
        end

      case response do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          case decode(body) do
            %{} = map -> {:ok, map}
            _ -> {:error, {:photon, status, %{}}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:photon, status, problem_details(decode(body))}}

        _ ->
          {:error, {:photon, :transport, %{}}}
      end
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp decode(body), do: body

  defp problem_details(body) when is_map(body) do
    for key <- ["code", "detail", "requestId"],
        value = body[key],
        is_binary(value),
        into: %{},
        do: {key, String.slice(value, 0, 1_000)}
  end

  defp problem_details(_body), do: %{}

  defp observe(operation, fun) do
    started = SystemsClock.monotonic_time()
    result = fun.()
    outcome = if match?({:ok, _}, result), do: "ok", else: "unavailable"
    emit(operation, outcome, started)
    result
  end

  defp emit(operation, outcome, started) do
    SystemsRuntime.Telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: SystemsClock.monotonic_time() - started},
      %{component: "salix_im", operation: operation, surface: "comma", outcome: outcome}
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp idempotency_key(kind),
    do:
      "comma-#{kind}-" <>
        Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

  defp require_configured, do: if(configured?(), do: :ok, else: {:error, :imessage_unavailable})
  defp req_options, do: config()[:req_options] || []

  defp url(path) do
    base = String.trim_trailing(config()[:base_url] || @base_url, "/")
    base <> "/v1/projects/" <> URI.encode_www_form(project_id()) <> path
  end

  defp headers, do: [{"authorization", "Bearer " <> config()[:api_key]}]
end
