defmodule SalixAgent.TestSupport.FakeRtspCamera do
  require SystemsRuntime.Proc

  @moduledoc """
  An RTSP camera for tests, modeled on a TP-LINK TL-IPC45AW captured on the
  office network (2026-10-09): one TCP connection; a `401` offering Basic
  first and Digest second (no qop), and only Digest accepted, with `uri`
  equal to the request line; one nonce for the whole session; a
  `Content-Base` ending in `/` and relative track controls; an SDP with H.264
  video (track1), PCMA audio (track2) and TP-LINK metadata (track3);
  `Session: 6E362053;timeout=15`; then the H.264 frames of
  `test/fixtures/camera_frames.h264` as RTP, a NAL unit per packet and FU-A
  fragments for NAL units over 1200 bytes.

  Only `path` is served; another path draws `404`. Options: `no_frames:
  true` closes the connection after PLAY; `redirect_to: url` answers
  DESCRIBE with `302`; `renonce_on: method` answers the first authorized
  request of that method with a `401` and a new nonce (`stale=true`);
  `rtp_before_play_reply: true` sends an RTP packet before the PLAY reply;
  `hevc: true` describes H.265 video, as the camera's main stream is;
  `session_control: value` adds a session-level `a=control`; `play_url: url`
  and `setup_url: url` answer PLAY and SETUP only on that url;
  `content_base: url` replaces the Content-Base;
  `p_frames: true` streams frames without a key frame, sends `:streamed` to
  `owner`, then stays silent. Each request line is sent to `owner` as
  `{:rtsp_request, line}` and its headers (lowercase names) as
  `{:rtsp_headers, method, headers}`.
  """

  import Bitwise

  @realm "TP-LINK IP-Camera"
  @nonce "8baee1d58631d65b0729a247a7da8465"
  @fragment 1_200
  @max_frames 200

  def start(owner, opts) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)

    pid =
      SystemsRuntime.Proc.spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        :gen_tcp.close(listen)
        serve(socket, "", opts |> Map.new() |> Map.merge(%{owner: owner, nonce: @nonce}))
      end)

    :ok = :gen_tcp.controlling_process(listen, pid)
    {:ok, port}
  end

  def nal_units do
    Path.join(__DIR__, "../fixtures/camera_frames.h264")
    |> File.read!()
    |> :binary.split([<<0, 0, 0, 1>>, <<0, 0, 1>>], [:global])
    |> Enum.reject(&(&1 == ""))
  end

  defp serve(socket, buffer, opts) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [line | headers] = String.split(head, "\r\n")
        SystemsRuntime.Proc.send(opts.owner, {:rtsp_request, line})
        [method, uri, _version] = String.split(line, " ")
        headers = Map.new(headers, &header/1)
        SystemsRuntime.Proc.send(opts.owner, {:rtsp_headers, method, headers})
        opts = reply(socket, method, uri, headers, opts)
        serve(socket, rest, opts)

      [_partial] ->
        case :gen_tcp.recv(socket, 0) do
          {:ok, data} -> serve(socket, buffer <> data, opts)
          {:error, _closed} -> :ok
        end
    end
  end

  defp header(line) do
    [key, value] = String.split(line, ":", parts: 2)
    {String.downcase(key), String.trim(value)}
  end

  # Returns the connection's options, with a new nonce after a re-challenge.
  defp reply(socket, method, uri, headers, opts) do
    cseq = headers["cseq"]
    authorized = method == "OPTIONS" or authorized?(method, uri, headers["authorization"], opts)

    if authorized and method == opts[:renonce_on] and not Map.get(opts, :renonced, false) do
      opts = %{opts | nonce: opts.nonce <> "-2"} |> Map.put(:renonced, true)
      respond(socket, 401, cseq, challenges(opts, ", stale=true"))
      opts
    else
      answer(socket, method, uri, cseq, authorized, opts)
      opts
    end
  end

  defp challenges(opts, extra \\ "") do
    digest = ~s(WWW-Authenticate: Digest realm="#{@realm}", nonce="#{opts.nonce}"#{extra})

    [~s(WWW-Authenticate: Basic realm="#{@realm}"), digest]
  end

  defp answer(socket, method, uri, cseq, authorized, opts) do
    cond do
      method == "OPTIONS" ->
        respond(socket, 200, cseq, ["Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN"])

      not authorized ->
        respond(socket, 401, cseq, challenges(opts))

      not served?(method, uri, opts) ->
        respond(socket, 404, cseq, [])

      method == "DESCRIBE" and opts[:redirect_to] ->
        respond(socket, 302, cseq, ["Location: #{opts.redirect_to}"])

      method == "DESCRIBE" ->
        sdp = sdp(opts)

        respond(
          socket,
          200,
          cseq,
          ["Content-Base: " <> content_base(opts), "Content-Type: application/sdp"],
          sdp
        )

      method == "SETUP" ->
        respond(socket, 200, cseq, [
          "Transport: RTP/AVP/TCP;unicast;interleaved=0-1",
          "Session: 6E362053;timeout=15"
        ])

      method == "PLAY" ->
        if opts[:rtp_before_play_reply] do
          [packet | _] = rtp_packets(1)
          :gen_tcp.send(socket, <<?$, 0, byte_size(packet)::16>> <> packet)
        end

        respond(socket, 200, cseq, [
          "Range: npt=0.000-",
          "Session: 6E362053",
          "RTP-Info: url=rtsp://192.168.5.33:554#{opts.path}/track1;seq=1;rtptime=0"
        ])

        if opts[:no_frames], do: :gen_tcp.close(socket), else: stream(socket, opts)

      true ->
        respond(socket, 200, cseq, [])
    end
  end

  defp authorized?(method, uri, "Digest " <> params, opts) do
    params =
      ~r/(\w+)="([^"]*)"/
      |> Regex.scan(params)
      |> Map.new(fn [_, key, value] -> {key, value} end)

    ha1 = md5("#{opts.username}:#{@realm}:#{opts.password}")
    ha2 = md5("#{method}:#{params["uri"]}")

    params["username"] == opts.username and params["uri"] == uri and
      params["nonce"] == opts.nonce and params["response"] == md5("#{ha1}:#{opts.nonce}:#{ha2}")
  end

  defp authorized?(_method, _uri, _authorization, _opts), do: false

  defp md5(value), do: :crypto.hash(:md5, value) |> Base.encode16(case: :lower)

  # A url the test names for SETUP or PLAY is the only one served for it;
  # otherwise any url under `path`.
  defp served?("SETUP", uri, %{setup_url: url}), do: uri == url
  defp served?("PLAY", uri, %{play_url: url}), do: uri == url
  defp served?(_method, uri, opts), do: String.starts_with?(URI.parse(uri).path || "", opts.path)

  defp content_base(opts), do: opts[:content_base] || "rtsp://192.168.5.33:554#{opts.path}/"

  # The camera's SDP, with the fixture's parameter sets.
  defp sdp(opts) do
    [sps, pps | _] = nal_units()

    video =
      if opts[:hevc],
        do: ["a=rtpmap:96 H265/90000", "a=fmtp:96 profile-id=1"],
        else: [
          "a=rtpmap:96 H264/90000",
          "a=fmtp:96 packetization-mode=1; profile-level-id=64001E; sprop-parameter-sets=#{Base.encode64(sps)},#{Base.encode64(pps)}"
        ]

    Enum.join(
      [
        "v=0",
        "o=- 14665860 31787219 1 IN IP4 192.168.5.33",
        ~s(s=Session streamed by "TP-LINK RTSP Server"),
        "t=0 0"
      ] ++
        List.wrap(if opts[:session_control], do: "a=control:" <> opts.session_control) ++
        [
          "m=video 0 RTP/AVP 96",
          "c=IN IP4 0.0.0.0",
          "b=AS:4096",
          "a=range:npt=0-",
          "a=control:track1"
        ] ++
        video ++
        [
          "m=audio 0 RTP/AVP 8",
          "a=rtpmap:8 PCMA/8000",
          "a=control:track2",
          "m=application/TP-LINK 0 RTP/AVP smart/1/90000",
          "a=rtpmap:95 TP-LINK/90000",
          "a=control:track3",
          ""
        ],
      "\r\n"
    )
  end

  defp respond(socket, status, cseq, headers, body \\ "") do
    reason = %{200 => "OK", 302 => "Found", 401 => "Unauthorized", 404 => "Not Found"}[status]
    lines = ["RTSP/1.0 #{status} #{reason}", "CSeq: #{cseq}" | headers]
    lines = if body == "", do: lines, else: lines ++ ["Content-Length: #{byte_size(body)}"]
    :gen_tcp.send(socket, Enum.join(lines, "\r\n") <> "\r\n\r\n" <> body)
  end

  @doc """
  The fixture's access units (each a list of NAL units): parameter sets
  and an IDR slice per frame. With `slices_only: true`, without the
  parameter sets; with `p_frames: true`, non-IDR slices only.
  """
  def access_units(opts \\ []) do
    if opts[:p_frames] do
      # A non-IDR slice (type 1) that never makes a key frame.
      [[<<0x41>> <> :binary.copy(<<0x9A>>, 1_500)]]
    else
      nal_units()
      |> Enum.chunk_while(
        [],
        fn nal, acc ->
          if (:binary.first(nal) &&& 0x1F) in [1, 5],
            do: {:cont, Enum.reverse([nal | acc]), []},
            else: {:cont, [nal | acc]}
        end,
        fn acc -> {:cont, Enum.reverse(acc), []} end
      )
      |> Enum.reject(&(&1 == []))
      |> Enum.map(fn nals ->
        if opts[:slices_only],
          do: Enum.filter(nals, &((:binary.first(&1) &&& 0x1F) in [1, 5])),
          else: nals
      end)
    end
  end

  @doc """
  RTP packets for `count` frames of `access_units(opts)`, repeated: a NAL
  unit per packet, FU-A over #{@fragment} bytes, the marker on each frame's
  last packet, 40 ms apart, sequence numbers from `:first_seq` (0).
  """
  def rtp_packets(count, opts \\ []) do
    units = access_units(opts) |> Enum.map(fn nals -> Enum.flat_map(nals, &packetize/1) end)

    units
    |> Stream.cycle()
    |> Enum.take(count)
    |> Enum.with_index()
    |> Enum.flat_map_reduce(Keyword.get(opts, :first_seq, 0), fn {payloads, frame}, seq ->
      last = length(payloads) - 1

      packets =
        payloads
        |> Enum.with_index()
        |> Enum.map(fn {payload, i} ->
          marker = if i == last, do: 1, else: 0
          seq = rem(seq + i, 65_536)
          timestamp = rem(frame * 3600, 0x100000000)

          <<2::2, 0::1, 0::1, 0::4, marker::1, 96::7, seq::16, timestamp::32, 0x1234::32>> <>
            payload
        end)

      {packets, seq + length(payloads)}
    end)
    |> elem(0)
  end

  # A camera streams until the client goes away (or `@max_frames` frames, 20 s
  # of video). With `p_frames: true` it then waits without closing.
  defp stream(socket, opts) do
    sent =
      @max_frames
      |> rtp_packets(p_frames: opts[:p_frames])
      |> Enum.reduce_while(:ok, fn packet, :ok ->
        case :gen_tcp.send(socket, <<?$, 0, byte_size(packet)::16>> <> packet) do
          :ok -> {:cont, :ok}
          {:error, _closed} -> {:halt, :closed}
        end
      end)

    if sent == :ok and opts[:p_frames] do
      SystemsRuntime.Proc.send(opts.owner, :streamed)
      # Idle until the client closes, so a test clock can settle.
      :ok = :inet.setopts(socket, active: true)
      await_close(socket)
    end

    :gen_tcp.close(socket)
  end

  defp await_close(socket) do
    SystemsRuntime.Proc.receive do
      {:tcp, ^socket, _data} -> await_close(socket)
      {:tcp_closed, ^socket} -> :ok
    end
  end

  defp packetize(nal) when byte_size(nal) <= @fragment, do: [nal]

  defp packetize(<<header, body::binary>>) do
    indicator = (header &&& 0xE0) ||| 28
    type = header &&& 0x1F
    parts = for <<part::binary-size(@fragment) <- body>>, do: part
    tail = binary_part(body, length(parts) * @fragment, rem(byte_size(body), @fragment))
    parts = if tail == "", do: parts, else: parts ++ [tail]
    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.map(fn {part, i} ->
      start = if i == 0, do: 1, else: 0
      stop = if i == last, do: 1, else: 0
      <<indicator, start::1, stop::1, 0::1, type::5>> <> part
    end)
  end
end
