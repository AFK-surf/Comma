defmodule Comma.ScreenStreamIceTest do
  use ExUnit.Case, async: false

  alias Comma.ScreenStreamIce

  setup do
    previous = SystemsRuntime.get_env(:comma_core, :screen_stream_turn)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:comma_core, :screen_stream_turn, previous),
        else: SystemsRuntime.delete_env(:comma_core, :screen_stream_turn)
    end)

    :ok
  end

  defp configure do
    SystemsRuntime.put_env(:comma_core, :screen_stream_turn,
      key_id: "key_1",
      api_token: "token_1",
      request_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  test "mints relay credentials with the configured key" do
    configure()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/turn/keys/key_1/credentials/generate-ice-servers"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token_1"]

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "iceServers" => [
          %{"urls" => ["stun:stun.cloudflare.com:3478"]},
          %{
            "urls" => ["turn:turn.cloudflare.com:3478?transport=udp"],
            "username" => "user",
            "credential" => "secret",
            "extra" => "dropped"
          },
          %{"urls" => []}
        ]
      })
    end)

    assert ScreenStreamIce.servers() == [
             %{"urls" => ["stun:stun.cloudflare.com:3478"]},
             %{
               "urls" => ["turn:turn.cloudflare.com:3478?transport=udp"],
               "username" => "user",
               "credential" => "secret"
             }
           ]
  end
end
