defmodule SalixAgent.RtspSnapshotTest do
  require SystemsRuntime.Proc

  @moduledoc """
  `SalixAgent.RtspSnapshot` against `SalixAgent.TestSupport.FakeRtspCamera`:
  its own RTSP client sends the requests a TP-LINK TL-IPC45AW accepts and
  takes the first key frame of the H.264 stream, the runtime's FFmpeg decodes
  it from a pipe to JPEG, and authentication, path, codec and redirect
  failures are named.
  """
  use SystemsClock.Case, async: true

  alias SalixAgent.RtspSnapshot
  alias SalixAgent.TestSupport.FakeRtspCamera

  @moduletag :ffmpeg
  # Characters that would break an unencoded url's userinfo.
  @password "Pa55:w0rd!@/%#"

  defp capture(camera_opts, url_path, credentials) do
    opts = Keyword.merge([username: "admin", password: @password, path: "/stream2"], camera_opts)
    {:ok, port} = FakeRtspCamera.start(SystemsRuntime.Proc.self(), opts)
    {:ok, upstream} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    RtspSnapshot.capture(upstream, "rtsp://192.168.5.33:554" <> url_path, credentials)
  end

  defp dimensions(<<0xFF, 0xD8, rest::binary>>), do: segments(rest)

  defp segments(<<0xFF, marker, _len::16, _precision, height::16, width::16, _::binary>>)
       when marker in 0xC0..0xC3,
       do: {width, height}

  defp segments(<<0xFF, _marker, len::16, rest::binary>>),
    do: segments(binary_part(rest, len - 2, byte_size(rest) - len + 2))

  # What the camera has received so far, in order: `{line, headers}`.
  defp requests(acc \\ []) do
    SystemsRuntime.Proc.receive do
      {:rtsp_request, line} ->
        SystemsRuntime.Proc.receive do
          {:rtsp_headers, _method, headers} -> requests([{line, headers} | acc])
        end
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp digest_fields("Digest " <> params) do
    ~r/(\w+)=("[^"]*"|[^\s,]+)/
    |> Regex.scan(params)
    |> Map.new(fn [_, key, value] -> {key, String.trim(value, ~s("))} end)
  end

  # The exchange a client that works with the camera sends (captured
  # 2026-10-09 from the office network).
  test "the frame comes back with the requests the TL-IPC45AW accepts" do
    assert {:ok, jpeg} = capture([], "/stream2", {"admin", @password})
    assert dimensions(jpeg) == {160, 90}

    # TEARDOWN is best effort: the camera reads it only after it stops
    # streaming, so the session up to PLAY is what it has surely received.
    sent = Enum.take(requests(), 4)

    assert Enum.map(sent, &elem(&1, 0)) == [
             "DESCRIBE rtsp://192.168.5.33:554/stream2 RTSP/1.0",
             "DESCRIBE rtsp://192.168.5.33:554/stream2 RTSP/1.0",
             "SETUP rtsp://192.168.5.33:554/stream2/track1 RTSP/1.0",
             "PLAY rtsp://192.168.5.33:554/stream2 RTSP/1.0"
           ]

    [{_, first} | authorized] = sent
    refute Map.has_key?(first, "authorization")

    for {line, headers} <- authorized do
      [_method, uri, _version] = String.split(line, " ")
      fields = digest_fields(headers["authorization"])
      # Digest, not Basic, with the fields the camera's challenge calls for.
      assert Map.keys(fields) |> Enum.sort() == ~w(nonce realm response uri username)
      assert fields["uri"] == uri
      assert fields["nonce"] == "8baee1d58631d65b0729a247a7da8465"
    end

    assert [_, _, {_, setup}, {_, play}] = sent
    refute Map.has_key?(setup, "session")
    assert play["session"] == "6E362053"
  end

  test "a wrong password is unauthorized" do
    assert {:error, :unauthorized, _} = capture([], "/stream2", {"admin", "wrong"})
    assert {:error, :unauthorized, _} = capture([], "/stream2", nil)
  end

  # The client never opens a connection of its own: a redirect is an error.
  test "a redirect from the camera is refused, and nothing connects elsewhere" do
    {:ok, elsewhere} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(elsewhere)

    assert {:error, :redirected, _} =
             capture(
               [redirect_to: "rtsp://127.0.0.1:#{port}/stream2"],
               "/stream2",
               {"admin", @password}
             )

    assert {:error, :timeout} = :gen_tcp.accept(elsewhere, 0)
  end
end
