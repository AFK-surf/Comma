defmodule SalixIM.IMessageRelay do
  @moduledoc """
  Narrow Req adapter for the project-owned Willow iMessage relay HTTP contract.
  BlueBubbles remains behind the relay. Redirects and automatic send retries are
  disabled: the bearer belongs to one configured origin and an ambiguous send
  is not evidence that nothing was delivered.
  An acknowledgement is a relay response, not an Apple delivery receipt.
  No cross-call deduplication is claimed.
  """

  @max_event_bytes 1024 * 1024
  @max_image_bytes 20 * 1024 * 1024

  def config, do: Application.get_env(:salix_im, :imessage, [])

  def configured? do
    config()[:enabled] == true and
      Enum.all?([:relay_id, :base_url, :bearer_token, :shared_handle], fn key ->
        is_binary(config()[key]) and String.trim(config()[key]) != ""
      end)
  end

  def relay_id, do: config()[:relay_id]
  def shared_handle, do: config()[:shared_handle]
  def shared_identity, do: config()[:shared_identity] || "Comma"

  def health, do: request(:get, "/v1/health")

  def tail do
    case request(:get, "/v1/events/tail") do
      {:ok, %{"latest_event_id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, body} when body == %{} -> {:ok, ""}
      _ -> {:error, :imessage_relay_unavailable}
    end
  end

  def send_text(sender, chat, text, selected_message_guid \\ nil) do
    body = %{"sender_handle" => sender, "chat_guid" => chat, "text" => text}

    body =
      if is_binary(selected_message_guid) and selected_message_guid != "",
        do: Map.put(body, "selected_message_guid", selected_message_guid),
        else: body

    request(:post, "/v1/messages/text", json: body) |> sent()
  end

  def send_image(sender, chat, upload, caption \\ "") do
    if byte_size(upload.data) <= @max_image_bytes do
      request(:post, "/v1/messages/image",
        form_multipart: %{
          sender_handle: sender,
          chat_guid: chat,
          caption: caption,
          image: {upload.data, filename: upload.filename}
        }
      )
      |> sent()
    else
      {:error, :imessage_image_too_large}
    end
  end

  # Framing is bounded independently of HTTP chunk boundaries. Handled events
  # alone advance the caller's checkpoint. A partial line survives to the next
  # chunk; a disconnect leaves its event unacknowledged for relay replay.
  def decode_chunk(buffer, chunk, handle) when is_binary(buffer) and is_binary(chunk) do
    consume_lines(buffer <> chunk, handle)
  end

  defp consume_lines(bytes, handle) do
    case :binary.match(bytes, "\n") do
      {offset, 1} when offset <= @max_event_bytes ->
        <<line::binary-size(^offset), "\n", rest::binary>> = bytes

        with :ok <- handle_line(line, handle) do
          consume_lines(rest, handle)
        end

      :nomatch when byte_size(bytes) <= @max_event_bytes ->
        {:ok, bytes}

      _ ->
        {:error, :imessage_event_too_large}
    end
  end

  defp handle_line("", _handle), do: :ok

  defp handle_line(line, handle) do
    case Jason.decode(line) do
      {:ok, %{"type" => "keepalive"}} -> :ok
      {:ok, %{"event_id" => id} = event} when is_binary(id) and id != "" -> handle.(event)
      _ -> {:error, :invalid_imessage_event}
    end
  end

  def stream(after_event_id, handle, opts \\ []) do
    observe("imessage_receive", fn -> do_stream(after_event_id, handle, opts) end)
  end

  defp do_stream(after_event_id, handle, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :duration_ms, 60_000)

    with :ok <- require_configured() do
      response =
        Req.get(url("/v1/events/stream"),
          headers: headers(),
          params: [after_event_id: after_event_id],
          retry: false,
          redirect: false,
          decode_body: false,
          receive_timeout: 35_000,
          connect_options: [timeout: 5_000],
          into: fn {:data, chunk}, {req, resp} ->
            result =
              if resp.status == 200,
                do: decode_chunk(resp.private[:imessage_buffer] || "", chunk, handle),
                else: {:error, :imessage_relay_unavailable}

            case result do
              {:ok, buffer} ->
                next = Req.Response.put_private(resp, :imessage_buffer, buffer)

                if System.monotonic_time(:millisecond) >= deadline,
                  do:
                    {:halt,
                     {req, Req.Response.put_private(next, :imessage_duration_elapsed, true)}},
                  else: {:cont, {req, next}}

              {:error, reason} ->
                {:halt, {req, Req.Response.put_private(resp, :imessage_error, reason)}}
            end
          end
        )

      case response do
        {:ok, %{status: 200, private: private}} ->
          cond do
            reason = private[:imessage_error] -> {:error, reason}
            private[:imessage_duration_elapsed] -> :ok
            (private[:imessage_buffer] || "") != "" -> {:error, :invalid_imessage_event}
            true -> :ok
          end

        _ ->
          {:error, :imessage_relay_unavailable}
      end
    end
  end

  def download_image(agent_id, attachment_id)
      when is_binary(attachment_id) and attachment_id != "" do
    alias SalixStore.Blob
    state_key = {__MODULE__, make_ref()}
    Process.put(state_key, Blob.put_stream_init(agent_id))

    try do
      with :ok <- require_configured() do
        response =
          Req.get(url("/v1/attachments/#{URI.encode_www_form(attachment_id)}/content"),
            headers: headers(),
            retry: false,
            redirect: false,
            decode_body: false,
            receive_timeout: 15_000,
            into: fn {:data, chunk}, {req, resp} ->
              size = (resp.private[:imessage_bytes] || 0) + byte_size(chunk)

              if resp.status == 200 and size <= @max_image_bytes do
                case Blob.put_stream_step(Process.get(state_key), chunk) do
                  {:ok, state} ->
                    Process.put(state_key, state)
                    {:cont, {req, Req.Response.put_private(resp, :imessage_bytes, size)}}

                  {:error, _, state} ->
                    Process.put(state_key, state)
                    {:halt, {req, Req.Response.put_private(resp, :imessage_error, true)}}
                end
              else
                {:halt, {req, Req.Response.put_private(resp, :imessage_error, true)}}
              end
            end
          )

        case response do
          {:ok, %{status: 200, private: private}} when not is_map_key(private, :imessage_error) ->
            with {:ok, ref} <- Blob.put_stream_finish(Process.get(state_key)) do
              Process.delete(state_key)
              {:ok, %{ref: ref, size: private[:imessage_bytes] || 0}}
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

  defp request(method, path, opts \\ []) do
    observe("imessage_request", fn -> do_request(method, path, opts) end)
  end

  defp do_request(method, path, opts) do
    with :ok <- require_configured() do
      response =
        Req.request(
          Keyword.merge(
            [
              method: method,
              url: url(path),
              headers: headers(),
              retry: false,
              redirect: false,
              receive_timeout: 15_000,
              connect_options: [timeout: 5_000]
            ],
            opts
          )
        )

      case response do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
          {:ok, body}

        _ ->
          {:error, :imessage_relay_unavailable}
      end
    end
  end

  defp observe(operation, fun), do: observe(operation, fun, System.monotonic_time())

  defp observe(operation, fun, started) do
    result = fun.()
    outcome = if result == :ok or match?({:ok, _}, result), do: "ok", else: "unavailable"
    emit(operation, outcome, started)
    result
  rescue
    exception ->
      emit(operation, "error", started)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      emit(operation, "error", started)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp emit(operation, outcome, started) do
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.monotonic_time() - started},
      %{component: "salix_im", operation: operation, surface: "comma", outcome: outcome}
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp sent({:ok, %{"message_id" => id} = result}) when is_binary(id) and id != "",
    do: {:ok, result}

  defp sent({:error, :imessage_unavailable} = error), do: error

  defp sent(_) do
    {:error,
     %{
       "code" => "imessage_delivery_unknown",
       "delivery_status" => "unknown",
       "retryable" => false,
       "message" =>
         "The relay did not acknowledge this send. The message may already have been sent. " <>
           "Do not retry this text/image, send a failure notice, or claim delivery. " <>
           "This integration has no delivery-verification API. Device or connection discovery cannot confirm this send. " <>
           "End this turn now with end_turn and outcome=blocked. " <>
           "Use a private reason: iMessage delivery is unknown. The user/operator must verify in Messages before a new send. " <>
           "Do not ask through iMessage or wait_for a human response."
     }}
  end

  defp require_configured, do: if(configured?(), do: :ok, else: {:error, :imessage_unavailable})
  defp url(path), do: String.trim_trailing(config()[:base_url], "/") <> path
  defp headers, do: [{"authorization", "Bearer " <> config()[:bearer_token]}]
end
