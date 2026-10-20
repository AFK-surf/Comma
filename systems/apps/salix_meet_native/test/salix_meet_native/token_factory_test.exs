defmodule SalixMeetNative.TokenFactoryTest do
  use ExUnit.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixMeetNative"]

  alias SalixMeetNative.{CodeClaim, TokenFactory}

  test "normalize_meeting_url accepts a bare code, a host path, and a full url; rejects junk" do
    assert {:ok, "https://meet.google.com/abc-defg-hij"} =
             TokenFactory.normalize_meeting_url("abc-defg-hij")

    assert {:ok, "https://meet.google.com/abc-defg-hij"} =
             TokenFactory.normalize_meeting_url("meet.google.com/abc-defg-hij")

    assert {:ok, "https://meet.google.com/abc-defg-hij"} =
             TokenFactory.normalize_meeting_url("https://meet.google.com/abc-defg-hij")

    assert {:error, :invalid_meeting_url} =
             TokenFactory.normalize_meeting_url("https://evil.example/x")

    assert {:error, :invalid_meeting_url} = TokenFactory.normalize_meeting_url("nonsense")
  end

  test "a guest handoff retries the guest factory's plain-text busy answer" do
    counter = :counters.new(1, [])

    plug = fn conn ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        n when n <= 2 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.send_resp(429, "Factory busy")

        _ ->
          Plug.Conn.send_resp(conn, 504, ~s({"stage":"container","reason":"timeout"}))
      end
    end

    started = SystemsClock.monotonic_time(:millisecond)

    assert {:error, {:http, 504, "container", "timeout", nil}} =
             TokenFactory.handoff("abc-defg-hij",
               url: "https://guest.example/v1/handoff",
               secret: "s",
               req_options: [plug: plug]
             )

    assert :counters.get(counter, 1) == 3
    # Each busy answer waits the 1 s retry floor on the clock, not in real time.
    assert SystemsClock.monotonic_time(:millisecond) - started == 2_000
  end

  test "a meeting code claim is released when its runtime stops" do
    key = {__MODULE__, make_ref()}
    {:ok, runtime} = Agent.start(fn -> nil end)

    assert {:ok, claim} = CodeClaim.claim(key, runtime)
    assert {:taken, ^runtime} = CodeClaim.claim(key, self())

    ref = Process.monitor(claim)
    Process.exit(runtime, :kill)
    settle_receive({:DOWN, ^ref, :process, ^claim, _})
    assert {:ok, _claim} = CodeClaim.claim(key, self())
  end
end
