defmodule CommaWeb.RecordingTranscription do
  @moduledoc """
  Authenticated recording uploads to the shared meeting ASR backend. With
  `?purpose=dictation` (Quick Chat's words) the transcript is plain text
  instead of timed speaker lines.
  """
  import Plug.Conn

  @max_bytes 30 * 1024 * 1024
  @timeout_ms 610_000

  def call(conn, opts \\ []) do
    conn = fetch_query_params(conn)
    purpose = if conn.query_params["purpose"] == "dictation", do: :dictation, else: :recording

    transcribe =
      Keyword.get(opts, :transcribe, fn stream, size, filename ->
        Salix.Bindings.AgentAudioTranscriber.transcribe_upload(stream, size, filename,
          purpose: purpose
        )
      end)

    path =
      Path.join(
        System.tmp_dir!(),
        "comma-asr-#{Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)}.m4a"
      )

    try do
      with [type] <- get_req_header(conn, "content-type"),
           true <- type == "audio/mp4",
           {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
        upload =
          try do
            read_upload(conn, file, 0)
          after
            File.close(file)
          end

        case upload do
          {:ok, conn, size} when size > 0 ->
            stream_result(
              conn,
              fn -> transcribe.(File.stream!(path, 262_144, []), size, "recording.m4a") end,
              purpose,
              opts
            )

          {:ok, conn, 0} ->
            error(conn, 400, "The recording is empty.")

          {:error, conn, :too_large} ->
            error(conn, 413, "ASR accepts recordings up to 30 MiB. The audio remains in Drive.")

          {:error, conn, _} ->
            error(conn, 400, "The recording upload failed.")
        end
      else
        _ -> error(conn, 400, "Upload an M4A recording with content type audio/mp4.")
      end
    after
      File.rm(path)
    end
  end

  defp read_upload(conn, file, size) do
    case read_body(conn, length: 262_144, read_length: 262_144, read_timeout: 15_000) do
      {status, bytes, conn} when status in [:ok, :more] ->
        size = size + byte_size(bytes)

        cond do
          size > @max_bytes -> {:error, conn, :too_large}
          IO.binwrite(file, bytes) != :ok -> {:error, conn, :write_failed}
          status == :ok -> {:ok, conn, size}
          true -> read_upload(conn, file, size)
        end

      {:error, reason} ->
        {:error, conn, reason}
    end
  end

  defp stream_result(conn, run, purpose, opts) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    task =
      SystemsRuntime.Task.async(fn ->
        try do
          run.()
        rescue
          _ -> {:error, :asr_failed}
        catch
          _, _ -> {:error, :asr_failed}
        end
      end)

    started_at = SystemsClock.monotonic_time()

    deadline =
      SystemsClock.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @timeout_ms)

    try do
      {conn, result} = await_result(conn, task, deadline)
      observe_result(result, purpose, SystemsClock.monotonic_time() - started_at)
      conn
    after
      SystemsRuntime.Task.shutdown(task, :brutal_kill)
    end
  end

  defp await_result(conn, task, deadline) do
    remaining = deadline - SystemsClock.monotonic_time(:millisecond)

    if remaining <= 0 do
      finish(conn, {:error, :timeout})
    else
      case SystemsRuntime.Task.yield(task, min(remaining, 15_000)) do
        {:ok, result} ->
          finish(conn, result)

        {:exit, _} ->
          finish(conn, {:error, :asr_failed})

        nil ->
          case chunk(conn, ": transcribing\n\n") do
            {:ok, conn} -> await_result(conn, task, deadline)
            {:error, _} -> {conn, {:error, :unavailable}}
          end
      end
    end
  end

  defp finish(conn, result), do: {terminal(conn, payload(result)), result}

  defp payload({:ok, result}), do: %{status: "ready", result: result}

  defp payload({:error, :asr_not_configured}),
    do: %{status: "error", reason: "Meeting ASR is not configured on the server."}

  defp payload({:error, :timeout}),
    do: %{status: "error", reason: "Transcription timed out. The audio remains in Drive."}

  defp payload(_),
    do: %{status: "error", reason: "Transcription failed. The audio remains in Drive."}

  defp observe_result(result, purpose, duration) do
    Salix.Telemetry.emit_operation(
      "salix_meet",
      if(purpose == :dictation, do: "dictation_asr", else: "meeting_asr"),
      "comma",
      Salix.Bindings.MeetingSummary.asr_telemetry_outcome(result),
      duration
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp terminal(conn, result) do
    case chunk(conn, "event: transcription\ndata: #{Jason.encode!(result)}\n\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
  end
end
