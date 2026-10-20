defmodule SalixSignal.CallMedia.RelaysTest do
  use SystemsClock.Case, async: true

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
end
