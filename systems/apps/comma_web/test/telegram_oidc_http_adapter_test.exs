defmodule CommaWeb.TelegramOIDC.HTTPAdapterTest do
  use ExUnit.Case, async: false

  alias CommaWeb.TelegramOIDC.HTTPAdapter

  setup_all do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  test "a discovery read survives one closed connection" do
    url = endpoint([:close, :ok])

    assert {:ok, {{_, 200, _}, _, "{}"}} = request(:get, url)
    assert_receive {:request, :close}
    assert_receive {:request, :ok}
  end

  test "persistent transport failure returns a safe reason after one retry" do
    url = endpoint([:close, :close, :ok])

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :phase, :reason_class]], fn ->
        assert {:error, {:telegram_oidc_transport, :closed}} = request(:get, url)
      end)

    assert_receive {:request, :close}
    assert_receive {:request, :close}
    refute_receive {:request, :ok}, 150
    assert log =~ "event=telegram_oidc_transport_failed"
    assert log =~ "phase=read"
    assert log =~ "reason_class=closed"
    refute log =~ "private-code"
    refute log =~ "private-body"
  end

  test "a token exchange is never replayed after the connection closes" do
    url = endpoint([:close, :ok])

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:phase]], fn ->
        assert {:error, {:telegram_oidc_transport, :closed}} = request(:post, url)
      end)

    assert log =~ "phase=exchange"
    refute log =~ "private-body"
    refute log =~ "private-code"
    assert_receive {:request, :close}
    refute_receive {:request, :ok}, 150
  end

  test "an HTTP response and its Retry-After are returned to the SDK without sleeping" do
    url = endpoint([:rate_limited, :ok])

    assert {:ok, {{_, 429, _}, _, "{}"}} = request(:get, url)
    assert_receive {:request, :rate_limited}
    refute_receive {:request, :ok}, 150
  end

  test "invalid request options retain a safe diagnostic without exposing request content" do
    assert {:error, {:telegram_oidc_transport, :invalid_request}} =
             HTTPAdapter.request(
               :get,
               {"http://localhost/private-code", []},
               [],
               [body_format: :binary],
               %{}
             )
  end

  defp request(method, url) do
    wire =
      if method == :post,
        do: {url, [], ~c"application/x-www-form-urlencoded", "private-body"},
        else: {url, []}

    HTTPAdapter.request(method, wire, [timeout: 1_000], [body_format: :binary], %{})
  end

  # A TCP fixture is required here: a Plug error is an HTTP response, not a
  # connection lost after the request was received. No provider is contacted.
  defp endpoint(outcomes) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    parent = self()

    pid = spawn_link(fn -> serve(listener, outcomes, parent) end)

    on_exit(fn ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)

    "http://127.0.0.1:#{port}/private-code"
  end

  defp serve(_listener, [], _parent), do: :ok

  defp serve(listener, [outcome | rest], parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
        send(parent, {:request, outcome})

        case outcome do
          :close ->
            :ok

          :ok ->
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
            )

          :rate_limited ->
            :gen_tcp.send(
              socket,
              "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 3600\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
            )
        end

        :gen_tcp.close(socket)
        serve(listener, rest, parent)

      {:error, :closed} ->
        :ok
    end
  end
end
