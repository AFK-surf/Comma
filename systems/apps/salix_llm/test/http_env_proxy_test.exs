defmodule SalixLlm.HttpEnvProxyTest do
  require SystemsRuntime.Proc

  # Mutates process environment variables.
  use SystemsClock.Case, async: false

  import ExUnit.CaptureLog

  alias SalixLlm.Http

  @vars ~w(HTTPS_PROXY https_proxy NO_PROXY no_proxy)
  @target "https://provider.example.invalid/v1"
  @proxy {:http, "proxy.example.invalid", 7890, []}

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  # A one-shot HTTP proxy: reports the request head of the first connection and
  # refuses it. Closing the returned listener reports :proxy_idle instead when
  # nothing connected.
  defp recording_proxy do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = SystemsRuntime.Proc.self()

    SystemsRuntime.Proc.spawn_link(fn ->
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          SystemsRuntime.Proc.send(test, {:proxy_request, read_head(socket, [])})
          :gen_tcp.send(socket, "HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n")
          :gen_tcp.close(socket)

        {:error, :closed} ->
          SystemsRuntime.Proc.send(test, :proxy_idle)
      end
    end)

    {port, listen}
  end

  defp read_head(socket, lines) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, "\r\n"} -> Enum.reverse(lines)
      {:ok, line} -> read_head(socket, [String.trim(line) | lines])
    end
  end

  defp proxied_head(url) do
    {port, listen} = recording_proxy()
    System.put_env("HTTPS_PROXY", "http://user:p%40ss@127.0.0.1:#{port}")
    Http.post(%{}, url, body: "{}", retry: false)
    # The proxy reports before it answers, so a connection made by the call has
    # already been reported by the time the call returns.
    :ok = :gen_tcp.close(listen)

    SystemsRuntime.Proc.receive do
      {:proxy_request, head} -> head
      :proxy_idle -> :direct
    end
  end

  test "HTTPS provider calls go through HTTPS_PROXY with its credentials" do
    assert ["CONNECT provider.example.invalid:443 HTTP/1.1" | headers] =
             proxied_head(@target <> "/messages")

    assert {"proxy-authorization", "Basic " <> Base.encode64("user:p@ss")} in Enum.map(
             headers,
             fn header ->
               [name, value] = String.split(header, ": ", parts: 2)
               {String.downcase(name), value}
             end
           )
  end

  test "NO_PROXY matches hosts, domain suffixes and ports case-insensitively" do
    System.put_env("HTTPS_PROXY", "http://proxy.example.invalid:7890")

    System.put_env(
      "NO_PROXY",
      "localhost, .Internal.Example,api.anthropic.com:443,api.openai.com:8443"
    )

    for url <- [
          "https://api.internal.example/v1",
          "https://INTERNAL.example/v1",
          "https://api.anthropic.com/v1/messages",
          "https://api.anthropic.com:443/v1/messages"
        ] do
      assert Http.env_proxy(url, []) == [], url
    end

    assert Http.env_proxy("https://api.openai.com/v1", []) == [connect_options: [proxy: @proxy]]

    assert Http.env_proxy("https://notinternal.example/v1", []) == [
             connect_options: [proxy: @proxy]
           ]
  end

  test "plain HTTP and loopback targets stay direct" do
    System.put_env("HTTPS_PROXY", "http://proxy.example.invalid:7890")

    for url <- [
          "http://ollama:11434/v1",
          "http://provider.example.invalid/v1",
          "https://localhost:8443/v1",
          "https://127.0.0.1/v1",
          "https://[::1]/v1"
        ] do
      assert Http.env_proxy(url, retry: false) == [retry: false], url
    end
  end

  test "proxy URL forms" do
    System.put_env("https_proxy", "proxy.example.invalid:7890")

    assert Http.env_proxy(@target, retry: false) == [
             connect_options: [proxy: @proxy],
             retry: false
           ]

    System.put_env("HTTPS_PROXY", "https://secure.example.invalid")

    assert Http.env_proxy(@target, connect_options: [timeout: 1]) ==
             [connect_options: [proxy: {:https, "secure.example.invalid", 443, []}, timeout: 1]]

    explicit = [connect_options: [proxy: {:http, "other.invalid", 1, []}]]
    assert Http.env_proxy(@target, explicit) == explicit

    System.put_env("HTTPS_PROXY", "socks5://proxy.example.invalid:1080")
    {opts, log} = with_log(fn -> Http.env_proxy(@target, []) end)
    assert opts == []
    assert log =~ "HTTPS_PROXY is not an http:// or https:// URL"
  end

  test "without HTTPS_PROXY nothing changes" do
    assert Http.env_proxy(@target, retry: false) == [retry: false]
  end
end
