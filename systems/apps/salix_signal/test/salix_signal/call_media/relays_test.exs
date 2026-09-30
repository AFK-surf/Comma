defmodule SalixSignal.CallMedia.RelaysTest do
  use ExUnit.Case, async: true

  alias SalixSignal.CallMedia.Relays

  # Shape of CRS-13 section 2.2; the values are Comma test data.
  @body Jason.encode!(%{
          "relays" => [
            %{
              "username" => "u1",
              "password" => "p1",
              "ttl" => 86_400,
              "urls" => [
                "turn:turn.example.test:3478?transport=udp",
                "turns:turn.example.test:443"
              ],
              "urlsWithIps" => [
                "turn:192.0.2.1:3478?transport=udp",
                "turn:192.0.2.1:3478?transport=tcp",
                "turn:[2001:db8::1]:3478?transport=udp"
              ],
              "hostname" => "turn.example.test"
            }
          ]
        })

  test "relays parse and become ICE servers, literal addresses first" do
    assert {:ok, %{relays: [relay], expires_at_ms: 86_401_000}} = Relays.parse(@body, 1_000)
    assert relay.hostname == "turn.example.test"

    assert [
             %{
               urls: [
                 "turn:192.0.2.1:3478?transport=udp",
                 "turn:turn.example.test:3478?transport=udp",
                 "turns:turn.example.test:443?transport=tcp"
               ],
               username: "u1",
               credential: "p1"
             }
           ] = Relays.ice_servers([relay])
  end

  test "Signal's Cloudflare UDP relay also offers the same service over TLS on 443" do
    relay = %{
      username: "user",
      password: "password",
      urls: ["stun:stun.cloudflare.com", "turn:turn.cloudflare.com"],
      urls_with_ips: ["turn:192.0.2.1"],
      hostname: "turn.cloudflare.com"
    }

    assert [%{urls: urls, username: "user", credential: "password"}] = Relays.ice_servers([relay])
    assert "turns:turn.cloudflare.com:443?transport=tcp" in urls
    assert "turn:192.0.2.1?transport=udp" in urls

    assert [%{urls: ["turn:other.example?transport=udp"]}] =
             Relays.ice_servers([%{relay | urls: ["turn:other.example"], urls_with_ips: []}])
  end

  test "fetch requests the relay path and maps failures" do
    assert {:ok, %{relays: [_]}} =
             Relays.fetch(fn "/v2/calling/relays" -> {:ok, 200, @body} end, 0)

    assert {:error, :rate_limited} = Relays.fetch(fn _ -> {:ok, 429, ""} end, 0)
    assert {:error, :unauthorized} = Relays.fetch(fn _ -> {:ok, 401, ""} end, 0)
    assert {:error, {:status, 500}} = Relays.fetch(fn _ -> {:ok, 500, ""} end, 0)

    assert {:error, :invalid_response} =
             Relays.fetch(fn _ -> {:ok, 200, ~s({"relays":[]})} end, 0)

    assert {:error, :invalid_response} = Relays.fetch(fn _ -> {:ok, 200, "{"} end, 0)
  end

  test "Signal URLs with an implicit UDP transport can create a TURN client" do
    body =
      Jason.encode!(%{
        relays: [
          %{
            username: "u1",
            password: "p1",
            ttl: 3600,
            urls: ["turn:192.0.2.1"],
            urlsWithIps: []
          }
        ]
      })

    assert {:ok, cache} = Relays.parse(body, 0)
    assert [%{urls: [url]} = server] = Relays.ice_servers(cache.relays)
    assert {:ok, uri} = ExSTUN.URI.parse(url)
    assert {:ok, _client} = ExTURN.Client.new(uri, server.username, server.credential)
  end
end
