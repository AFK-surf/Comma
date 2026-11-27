defmodule SalixIM.LarkAPIErrorsTest do
  @moduledoc """
  What an error of the Lark and Feishu OpenAPI clients keeps of a refused
  request: the platform code and Lark's request id when the answer carries
  them, and never the text of a body of another shape.
  """
  use SystemsClock.Case, async: false

  alias SalixIM.Provider.Feishu.API, as: FeishuAPI
  alias SalixIM.Provider.Lark.API, as: LarkAPI
  alias SalixIM.Provider.Lark.MeetingBot
  alias SalixIM.TestSupport.BanditServer

  defmodule Gateway do
    @moduledoc "Answers each path with one shape of refusal."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.path_info do
        ["open-apis", "envelope"] ->
          json(conn, 400, [], %{"code" => 230_002, "msg" => "Bot is not in the chat"})

        ["open-apis", "envelope-logged"] ->
          json(conn, 400, [{"x-tt-logid", "20261112ABC"}], %{
            "code" => 99_991_663,
            "msg" => "Invalid access token",
            "error" => %{"log_id" => "20261112ABC"}
          })

        ["open-apis", "forbidden"] ->
          raw(conn, 403, [{"x-tt-logid", "20261112DEF"}], "<html>Forbidden: private text</html>")

        ["open-apis", "forbidden-unsafe-id"] ->
          raw(conn, 403, [{"x-tt-logid", "id with spaces"}], "Forbidden")

        ["open-apis", "code-as-text"] ->
          raw(
            conn,
            403,
            [],
            Jason.encode!(%{
              "code" => 99_991_672,
              "message" => "private text",
              "error" => %{"log_id" => "20261112GHI"}
            })
          )
      end
    end

    defp json(conn, status, headers, body),
      do:
        conn
        |> merge_resp_headers(headers)
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

    defp raw(conn, status, headers, body),
      do:
        conn
        |> merge_resp_headers([{"content-type", "text/plain"} | headers])
        |> send_resp(status, body)
  end

  setup do
    base = BanditServer.serve!(Gateway) <> "/open-apis"

    previous =
      {SystemsRuntime.get_env(:salix_im, :lark_api_base_url),
       SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)}

    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, base)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, base)

    on_exit(fn ->
      {lark, feishu} = previous
      restore(:lark_api_base_url, lark)
      restore(:feishu_api_base_url, feishu)
    end)

    # A token given with the connect: no token is minted or refreshed.
    {:ok, connect: %{"tenant_access_token" => "t-given"}}
  end

  test "the common envelope reads as before, with Lark's request id when it names one", %{
    connect: connect
  } do
    assert {:error, "Lark API error 230002 (HTTP 400): Bot is not in the chat." <> action} =
             LarkAPI.get(connect, "/envelope")

    refute action =~ "log_id"

    assert {:error,
            "Lark API error 99991663 (HTTP 400): Invalid access token. (log_id 20261112ABC)"} =
             LarkAPI.get(connect, "/envelope-logged")
  end

  test "a refusal of another shape keeps its status and request id, not its text", %{
    connect: connect
  } do
    assert {:error, "Lark HTTP 403 (log_id 20261112DEF)" = reason} =
             LarkAPI.get(connect, "/forbidden")

    assert MeetingBot.http_status(reason) == 403
    assert MeetingBot.error_code(reason) == nil

    assert {:error, "Lark HTTP 403"} = LarkAPI.get(connect, "/forbidden-unsafe-id")

    # JSON sent as text, with a code and no `msg`: the code is read.
    assert {:error, "Lark API error 99991672 (HTTP 403)." <> rest = coded} =
             LarkAPI.get(connect, "/code-as-text")

    assert rest =~ "Missing Lark permission"
    assert String.ends_with?(rest, " (log_id 20261112GHI)")
    refute coded =~ "private text"
    assert MeetingBot.error_code(coded) == 99_991_672
    assert MeetingBot.http_status(coded) == nil
  end

  test "the Feishu client reads the same answers the same way", %{connect: connect} do
    assert {:error, "Feishu HTTP 403 (log_id 20261112DEF)"} = FeishuAPI.get(connect, "/forbidden")

    assert {:error, "Feishu API error 99991672 (HTTP 403)." <> rest} =
             FeishuAPI.get(connect, "/code-as-text")

    refute rest =~ "private text"

    assert {:error, "Feishu API error 230002 (HTTP 400): Bot is not in the chat." <> _} =
             FeishuAPI.get(connect, "/envelope")
  end

  defp restore(key, nil), do: SystemsRuntime.delete_env(:salix_im, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:salix_im, key, value)
end
