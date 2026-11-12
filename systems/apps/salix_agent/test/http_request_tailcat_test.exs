defmodule SalixAgent.HttpRequestTailcatTest do
  require SystemsRuntime.Proc

  @moduledoc """
  `web.http_request` and Salix's own exchange with `tailcat`: the request goes to a port of a Tailcat
  server through the node's gateway, as a still.fail station's Tailcat link
  serves its data outflow, and nowhere else.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.SSH.TailcatGateway
  alias SalixAgent.Tools.HttpRequest

  test "a request reaches the HTTP server behind a Tailcat server's port" do
    {port, served} = http_server!()
    peer = tailcat_peer!("127.0.0.1:#{port}")
    gateway!(peer.derp_map_url)

    response =
      Jason.decode!(
        HttpRequest.request(
          %{
            "url" => "http://stillfail:22/v1/request",
            "method" => "POST",
            "body" => %{"scopes" => ["usage"]},
            "tailcat" => peer.address
          },
          %{agent_id: SalixAgent.TestSupport.new_agent_id()}
        )
      )

    assert %{"status" => 200, "body" => %{"ok" => true}} = response

    request = SystemsRuntime.Task.await(served, :infinity)
    assert request =~ "POST /v1/request HTTP/1.1\r\n"
    assert request =~ "host: stillfail:22\r\n"
    assert request =~ ~s({"scopes":["usage"]})
  end

  test "tailcat is a Tailcat address, and not combined with via_tailnet" do
    ctx = %{agent_id: SalixAgent.TestSupport.new_agent_id()}

    assert_raise RuntimeError, ~r/tailcat must be a Tailcat address/, fn ->
      HttpRequest.request(%{"url" => "http://stillfail:22/", "tailcat" => 7}, ctx)
    end

    assert_raise RuntimeError, ~r/cannot be combined/, fn ->
      HttpRequest.request(
        %{"url" => "http://stillfail:22/", "tailcat" => "tcabc", "via_tailnet" => true},
        ctx
      )
    end
  end

  # One HTTP request answered with a JSON body; the task gives what came.
  defp http_server! do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    served =
      SystemsRuntime.Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 15_000)
        request = read_request(socket, "")
        body = ~s({"ok":true})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <>
              body
          )

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        request
      end)

    {port, served}
  end

  # The head and the body its content-length says.
  defp read_request(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length =
          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        if byte_size(body) >= length,
          do: acc,
          else: read_more(socket, acc)

      [_] ->
        read_more(socket, acc)
    end
  end

  defp read_more(socket, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 15_000)
    read_request(socket, acc <> data)
  end

  # A Tailcat server behind a local relay (systems/tailcat-gateway
  # cmd/tailcat-testpeer), forwarding its port 22 to target.
  defp tailcat_peer!(target) do
    exe = Path.join(:code.priv_dir(:salix_agent), "tailcat_testpeer")
    source = Path.expand("../../../tailcat-gateway", __DIR__)
    {_, 0} = System.cmd("make", ["-s", "-C", source, "testpeer", "TESTPEER=" <> exe])

    port =
      Port.open({:spawn_executable, exe}, [:binary, {:line, 65_536}, args: ["--target", target]])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    SystemsRuntime.Proc.receive do
      {^port, {:data, {:eol, line}}} ->
        %{"address" => address, "derp_map_url" => url} = Jason.decode!(line)
        %{address: address, derp_map_url: url}
    after
      15_000 -> flunk("the Tailcat test peer did not start")
    end
  end

  # A gateway that trusts the peer's local relay map.
  defp gateway!(derp_map_url) do
    name = :"tailcat_gateway_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    start_supervised!({TailcatGateway, name: name, derp_map_url: derp_map_url}, id: name)
    previous = SystemsRuntime.get_env(:salix_agent, :tailcat_gateway)
    SystemsRuntime.put_env(:salix_agent, :tailcat_gateway, name)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :tailcat_gateway, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :tailcat_gateway)
    end)
  end
end
