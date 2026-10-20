defmodule SalixAgent.RtspSnapshot do
  @moduledoc """
  One JPEG frame from a camera's RTSP stream, for `device.lan_request` with an
  `rtsp://` url. Cameras such as the TP-LINK TL-IPC45AW have no HTTP snapshot
  (ONVIF `GetSnapshotUri` is not supported), so the picture comes from the
  video stream.

  The RTSP client is here rather than FFmpeg's: FFmpeg opens connections of
  its own (it follows a redirect from the camera), and this server runs inside
  the private network, so a camera could make it reach other addresses
  (server-side request forgery). Here every byte goes through the one socket
  `capture/4` is given, the gateway's `lan_tcp_dial` tunnel from
  `SalixAgent.SSH.DeviceRelay.dial/5`; a redirect is an error, never followed.

  The client sends DESCRIBE, SETUP (RTP over the RTSP connection,
  interleaved) and PLAY, answers a `401` with the saved password (Digest
  through `SalixAgent.HttpDigestAuth`, or Basic when that is all the camera
  offers), and reads RTP until `SalixAgent.RtpH264` has a complete key frame.
  FFmpeg only decodes that frame: it reads H.264 from a pipe, with `pipe` as
  its only allowed protocol, and writes a JPEG of at most 1280 pixels on the
  longer side. The camera's bytes are bounded by `@max_stream_bytes` and the
  whole capture by `:timeout_ms`. The password never reaches a log or the
  result.
  """

  require SystemsClock

  alias SalixAgent.{HttpDigestAuth, RtpH264}

  @max_stream_bytes 16 * 1024 * 1024
  # One RTSP reply or interleaved packet, waiting for its end.
  @max_message_bytes 256 * 1024
  @max_jpeg_bytes 2 * 1024 * 1024

  @type credentials :: {String.t(), String.t()} | nil

  @doc """
  The first key frame of the H.264 stream at `url` (`rtsp://host[:port]/path`)
  as JPEG, read through `socket`, connected to the camera. `socket` is closed
  when this returns. Errors are `{:error, reason, detail}`, where `detail`
  names the RTSP `"step"` and `"status"` of a failed request: `:unauthorized`,
  `:unsupported_auth`, `:stream_not_found`, `:redirected`,
  `:unsupported_codec`, `:camera_refused`, `:camera_protocol`,
  `:camera_closed`, `:timeout`, `:oversized`, `:no_frame`,
  `:ffmpeg_unavailable`.
  """
  @spec capture(:gen_tcp.socket(), String.t(), credentials(), keyword()) ::
          {:ok, binary()} | {:error, atom(), map()}
  def capture(socket, url, credentials, opts \\ []) do
    deadline =
      SystemsClock.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 20_000)

    session = %{
      socket: socket,
      credentials: credentials,
      auth: nil,
      cseq: 0,
      session: nil,
      buffer: "",
      bytes: 0,
      deadline: deadline
    }

    try do
      :ok = :inet.setopts(socket, mode: :binary, active: false)

      with {:ok, s, described} <- request(session, "DESCRIBE", url, ["Accept: application/sdp"]),
           {:ok, track} <- video_track(described, url),
           {:ok, s, set_up} <-
             request(s, "SETUP", track.control, [
               "Transport: RTP/AVP/TCP;unicast;interleaved=0-1"
             ]),
           {:ok, session_id, channel} <- transport(set_up),
           {:ok, s, _playing} <-
             request(%{s | session: session_id}, "PLAY", track.base, ["Range: npt=0.000-"]),
           {:ok, s, frame} <- read_frame(s, channel, RtpH264.new(track.parameter_sets)) do
        teardown(s, track.base)
        decode(frame, deadline)
      end
      |> case do
        {:error, reason} -> {:error, reason, %{}}
        result -> result
      end
    after
      :gen_tcp.close(socket)
    end
  end

  ## RTSP requests

  # A 401 is answered once per request: first with the camera's challenge,
  # and again only when the camera sends a new nonce (some ask again on SETUP).
  # A same-nonce 401 ends the capture: repeating a wrong password would lock
  # the camera account.
  defp request(s, method, uri, headers, answered \\ false) do
    s = %{s | cseq: s.cseq + 1}

    with {:ok, auth_lines} <- authorization(s, method, uri),
         lines =
           ["#{method} #{uri} RTSP/1.0", "CSeq: #{s.cseq}", "User-Agent: Salix"] ++
             auth_lines ++ session_header(s) ++ headers,
         :ok <- send_bytes(s, Enum.join(lines, "\r\n") <> "\r\n\r\n"),
         {:ok, s, reply} <- read_reply(s) do
      case reply.status do
        status when status in 200..299 ->
          {:ok, s, reply}

        401 when not answered and not is_nil(s.credentials) ->
          case challenge(reply) do
            {:ok, auth} ->
              if fresh?(s.auth, auth),
                do: request(%{s | auth: auth}, method, uri, headers, true),
                else: failed(:unauthorized, method, 401)

            {:error, reason} ->
              failed(reason, method, 401)
          end

        401 ->
          failed(:unauthorized, method, 401)

        404 ->
          failed(:stream_not_found, method, 404)

        status when status in 300..399 ->
          failed(:redirected, method, status)

        status ->
          failed(:camera_refused, method, status)
      end
    else
      {:error, reason} -> failed(reason, method, nil)
    end
  end

  defp failed(reason, method, status),
    do: {:error, reason, %{"step" => method, "status" => status}}

  defp fresh?(nil, _auth), do: true

  defp fresh?({:digest, old}, {:digest, new}),
    do: old["nonce"] != new["nonce"] or String.downcase(new["stale"] || "") == "true"

  defp fresh?(_old, _new), do: false

  defp authorization(
         %{auth: {:digest, challenge}, credentials: {username, password}},
         method,
         uri
       ) do
    case HttpDigestAuth.authorization(challenge, method, uri, username, password) do
      {:ok, header} -> {:ok, ["Authorization: " <> header]}
      {:error, :unsupported} -> {:error, :unsupported_auth}
    end
  end

  defp authorization(%{auth: :basic, credentials: {username, password}}, _method, _uri),
    do: {:ok, ["Authorization: Basic " <> Base.encode64(username <> ":" <> password)]}

  defp authorization(_s, _method, _uri), do: {:ok, []}

  defp session_header(%{session: nil}), do: []
  defp session_header(%{session: session}), do: ["Session: " <> session]

  # Digest when the camera offers it, Basic only when that is all it offers.
  defp challenge(reply) do
    values = header_values(reply, "www-authenticate")

    case HttpDigestAuth.challenge(values) do
      %{} = challenge ->
        {:ok, {:digest, challenge}}

      nil ->
        if Enum.any?(values, &String.match?(&1, ~r/\Abasic\b/i)),
          do: {:ok, :basic},
          else: {:error, :unauthorized}
    end
  end

  defp teardown(s, uri) do
    {:ok, auth_lines} = authorization(s, "TEARDOWN", uri)

    lines =
      ["TEARDOWN #{uri} RTSP/1.0", "CSeq: #{s.cseq + 1}", "User-Agent: Salix"] ++
        auth_lines ++ session_header(s)

    send_bytes(s, Enum.join(lines, "\r\n") <> "\r\n\r\n")
  end

  defp send_bytes(s, data) do
    case :gen_tcp.send(s.socket, data) do
      :ok -> :ok
      {:error, _closed} -> {:error, :camera_closed}
    end
  end

  ## Reading the connection

  # A reply; interleaved packets before it are skipped.
  defp read_reply(%{buffer: <<?$, _channel, length::16, rest::binary>>} = s)
       when byte_size(rest) >= length do
    read_reply(%{s | buffer: binary_part(rest, length, byte_size(rest) - length)})
  end

  defp read_reply(%{buffer: <<?$, _::binary>>} = s), do: read_more(s, &read_reply/1)

  defp read_reply(%{buffer: buffer} = s) do
    case :binary.match(buffer, "\r\n\r\n") do
      {at, 4} ->
        with {:ok, reply} <- parse_head(binary_part(buffer, 0, at)) do
          size = at + 4 + reply.length

          if byte_size(buffer) < size do
            read_more(s, &read_reply/1)
          else
            body = binary_part(buffer, at + 4, reply.length)
            rest = binary_part(buffer, size, byte_size(buffer) - size)
            {:ok, %{s | buffer: rest}, Map.put(reply, :body, body)}
          end
        end

      :nomatch ->
        read_more(s, &read_reply/1)
    end
  end

  defp parse_head(head) do
    [status | lines] = String.split(head, "\r\n")

    with [_, code] <- Regex.run(~r/\ARTSP\/[0-9]\.[0-9] +([0-9]{3})/, status),
         headers =
           for(
             line <- lines,
             [name, value] <- [String.split(line, ":", parts: 2)],
             do: {String.downcase(String.trim(name)), String.trim(value)}
           ),
         {:ok, length} <- content_length(headers) do
      {:ok, %{status: String.to_integer(code), headers: headers, length: length}}
    else
      _malformed -> {:error, :camera_protocol}
    end
  end

  defp content_length(headers) do
    case List.keyfind(headers, "content-length", 0) do
      nil ->
        {:ok, 0}

      {_, value} ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 and length <= @max_message_bytes -> {:ok, length}
          _other -> {:error, :camera_protocol}
        end
    end
  end

  defp read_frame(%{buffer: <<?$, ch, length::16, rest::binary>>} = s, channel, rtp)
       when byte_size(rest) >= length do
    <<packet::binary-size(^length), rest::binary>> = rest
    s = %{s | buffer: rest}

    if ch == channel do
      case RtpH264.push(rtp, packet) do
        {:frame, frame} -> {:ok, s, frame}
        {:more, rtp} -> read_frame(s, channel, rtp)
        {:error, reason} -> {:error, reason}
      end
    else
      read_frame(s, channel, rtp)
    end
  end

  defp read_frame(%{buffer: <<?$, _::binary>>} = s, channel, rtp),
    do: read_more(s, &read_frame(&1, channel, rtp))

  # A reply during play, such as to a keep-alive.
  defp read_frame(%{buffer: <<"RTSP/", _::binary>>} = s, channel, rtp) do
    with {:ok, s, _reply} <- read_reply(s), do: read_frame(s, channel, rtp)
  end

  defp read_frame(%{buffer: buffer} = s, channel, rtp) when byte_size(buffer) < 5 do
    if String.starts_with?("RTSP/", buffer),
      do: read_more(s, &read_frame(&1, channel, rtp)),
      else: {:error, :camera_protocol}
  end

  defp read_frame(_s, _channel, _rtp), do: {:error, :camera_protocol}

  defp read_more(%{buffer: buffer}, _next) when byte_size(buffer) > @max_message_bytes,
    do: {:error, :oversized}

  defp read_more(%{socket: socket} = s, next) do
    :ok = :inet.setopts(socket, active: :once)
    remaining = max(s.deadline - SystemsClock.monotonic_time(:millisecond), 0)

    SystemsClock.vreceive do
      {:tcp, ^socket, data} ->
        bytes = s.bytes + byte_size(data)

        if bytes > @max_stream_bytes,
          do: {:error, :oversized},
          else: next.(%{s | buffer: s.buffer <> data, bytes: bytes})

      {:tcp_closed, ^socket} ->
        {:error, :camera_closed}

      {:tcp_error, ^socket, _reason} ->
        {:error, :camera_closed}
    after
      remaining -> {:error, :timeout}
    end
  end

  defp header_values(reply, name), do: for({^name, value} <- reply.headers, do: value)

  defp header(reply, name) do
    case List.keyfind(reply.headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  ## The session description

  defp video_track(reply, url) do
    base = header(reply, "content-base") || header(reply, "content-location") || url
    lines = String.split(reply.body, ~r/\r?\n/, trim: true)
    session_lines = Enum.take_while(lines, &(not String.starts_with?(&1, "m=")))

    case Enum.drop_while(lines, &(not String.starts_with?(&1, "m=video "))) do
      ["m=video " <> media | rest] ->
        attributes = Enum.take_while(rest, &(not String.starts_with?(&1, "m=")))
        payload_type = media |> String.split(" ") |> Enum.at(2)

        if h264?(attributes, payload_type) do
          {:ok,
           %{
             base: aggregate_url(attribute(session_lines, "control"), base, url),
             control: control_url(base, attribute(attributes, "control")),
             parameter_sets: parameter_sets(attributes, payload_type)
           }}
        else
          {:error, :unsupported_codec}
        end

      _no_video ->
        {:error, :unsupported_codec}
    end
  end

  defp attribute(attributes, name) do
    Enum.find_value(attributes, fn line ->
      case String.split(line, ":", parts: 2) do
        ["a=" <> ^name, value] -> String.trim(value)
        _ -> nil
      end
    end)
  end

  defp h264?(attributes, payload_type) when is_binary(payload_type) do
    prefix = "a=rtpmap:" <> payload_type <> " "

    Enum.any?(attributes, fn line ->
      String.starts_with?(line, prefix) and
        String.match?(String.replace_prefix(line, prefix, ""), ~r/\AH264\//i)
    end)
  end

  defp h264?(_attributes, _payload_type), do: false

  defp parameter_sets(attributes, payload_type) do
    prefix = "a=fmtp:" <> payload_type <> " "

    attributes
    |> Enum.find_value("", fn line ->
      with true <- String.starts_with?(line, prefix),
           [_, sets] <- Regex.run(~r/sprop-parameter-sets=([^;\s]+)/, line) do
        sets
      else
        _ -> nil
      end
    end)
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn set ->
      case Base.decode64(set, padding: false) do
        {:ok, nal} -> [nal]
        :error -> []
      end
    end)
  end

  # PLAY and TEARDOWN go to the session's control url (RFC 2326, C.1.1): an
  # absolute one as given, `*` the base url, a relative one resolved against
  # the base. Without one they go to the url that was described, as a TP-LINK
  # camera answers them (captured 2026-10-09: `…/stream2`, not its
  # Content-Base `…/stream2/`).
  defp aggregate_url(control, _base, url) when control in [nil, ""], do: url
  defp aggregate_url(control, base, _url), do: control_url(base, control)

  # A control url resolves against the base as a URI reference (RFC 3986),
  # except a bare segment such as `track1` against a base without a trailing
  # slash: strict resolution would replace the base's last segment, but
  # cameras mean a resource under it (`…/stream2` + `track1` is
  # `…/stream2/track1`), as common RTSP clients read it.
  defp control_url(base, control) when control in [nil, "", "*"], do: base

  defp control_url(base, control) do
    cond do
      URI.parse(control).scheme != nil ->
        control

      String.starts_with?(control, "/") or String.ends_with?(base, "/") ->
        to_string(URI.merge(base, control))

      true ->
        base <> "/" <> control
    end
  end

  defp transport(reply) do
    case header(reply, "session") do
      session when is_binary(session) and session != "" ->
        session = session |> String.split(";") |> hd() |> String.trim()

        channel =
          case Regex.run(~r/interleaved=([0-9]+)/, header(reply, "transport") || "") do
            [_, channel] -> String.to_integer(channel)
            nil -> 0
          end

        {:ok, session, channel}

      _missing ->
        {:error, :camera_protocol}
    end
  end

  ## Decoding

  # `head -c` passes exactly the frame's bytes and then closes FFmpeg's input,
  # which an Erlang port cannot do on its own.
  defp decode(frame, deadline) do
    with ffmpeg when is_binary(ffmpeg) <- System.find_executable("ffmpeg"),
         shell when is_binary(shell) <- System.find_executable("sh") do
      args =
        ["-c", ~S(n=$1 f=$2; shift 2; head -c "$n" | exec "$f" "$@"), "sh"] ++
          [Integer.to_string(byte_size(frame)), ffmpeg] ++
          ~w(-nostdin -hide_banner -loglevel quiet -protocol_whitelist pipe -f h264 -i pipe:0
             -frames:v 1 -an -map_metadata -1 -threads 1) ++
          ["-vf", "scale=w='min(1280,iw)':h='min(1280,ih)':force_original_aspect_ratio=decrease"] ++
          ~w(-c:v mjpeg -q:v 4 -f image2pipe pipe:1)

      port = Port.open({:spawn_executable, shell}, [:binary, :exit_status, args: args])

      try do
        Port.command(port, frame)
        collect(port, deadline, "")
      after
        if Port.info(port), do: Port.close(port)
      end
    else
      nil -> {:error, :ffmpeg_unavailable}
    end
  end

  defp collect(port, deadline, output) do
    remaining = max(deadline - SystemsClock.monotonic_time(:millisecond), 0)

    SystemsClock.vreceive do
      {^port, {:data, data}} ->
        if byte_size(output) + byte_size(data) <= @max_jpeg_bytes,
          do: collect(port, deadline, output <> data),
          else: {:error, :oversized}

      {^port, {:exit_status, 0}} ->
        case output do
          <<0xFF, 0xD8, _::binary>> -> {:ok, output}
          _ -> {:error, :no_frame}
        end

      {^port, {:exit_status, _status}} ->
        {:error, :no_frame}
    after
      remaining -> {:error, :timeout}
    end
  end
end
