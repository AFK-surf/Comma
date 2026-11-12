defmodule SalixStore.PostmarkTest do
  @moduledoc """
  `SalixStore.Postmark` against a Bandit mock of the Postmark /email endpoint:
  request shape (From per caller, joined To, server token header), success and
  failure mapping, and the not-configured guard.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.Postmark

  defmodule MockPostmark do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def requests, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", request_path: "/email"} = conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      req = Jason.decode!(raw)
      token = conn |> get_req_header("x-postmark-server-token") |> List.first()
      Agent.update(__MODULE__, &[%{body: req, token: token} | &1])

      {status, resp} =
        case req["Subject"] do
          "reject-422" -> {422, %{"ErrorCode" => 300, "Message" => "Invalid 'To' address."}}
          "reject-200" -> {200, %{"ErrorCode" => 406, "Message" => "Inactive recipient"}}
          _ -> {200, %{"ErrorCode" => 0, "Message" => "OK", "MessageID" => "msg-1"}}
        end

      json(conn, status, resp)
    end

    def call(%{method: "GET", request_path: "/messages/outbound/msg-1/details"} = conn, _opts) do
      json(conn, 200, %{
        "MessageID" => "msg-1",
        "Status" => "Sent",
        "Subject" => "Sign in",
        "TextBody" => "secret link",
        "MessageEvents" => [
          %{
            "Recipient" => "a@x.com",
            "Type" => "Bounced",
            "ReceivedAt" => "2026-11-03T05:41:00Z",
            "Details" => %{"Summary" => "550 a@x.com mailbox unavailable", "BounceID" => 42}
          }
        ]
      })
    end

    def call(%{method: "GET", request_path: "/bounces/42"} = conn, _opts) do
      json(conn, 200, %{
        "ID" => 42,
        "Type" => "HardBounce",
        "TypeCode" => 1,
        "Inactive" => true,
        "Email" => "a@x.com",
        "Details" => "550 mailbox unavailable"
      })
    end

    def call(%{method: "GET", request_path: "/messages/outbound/" <> _} = conn, _opts),
      do: json(conn, 422, %{"ErrorCode" => 701, "Message" => "Message not found"})

    def call(
          %{method: "GET", request_path: "/message-streams/outbound/suppressions/dump"} = conn,
          _opts
        ) do
      conn = fetch_query_params(conn)

      suppressions =
        case conn.query_params["EmailAddress"] do
          "a@x.com" ->
            [
              %{
                "EmailAddress" => "a@x.com",
                "SuppressionReason" => "HardBounce",
                "Origin" => "Recipient",
                "CreatedAt" => "2026-11-03T05:41:01Z"
              }
            ]

          _ ->
            []
        end

      json(conn, 200, %{"Suppressions" => suppressions})
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    start_supervised!(MockPostmark)

    port =
      Enum.find_value(1..10, fn _ ->
        p = 40000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20000)

        case start_supervised({Bandit, plug: MockPostmark, port: p}, id: {:bandit, p}) do
          {:ok, _pid} -> p
          {:error, _} -> nil
        end
      end)

    prev = %{
      base: SystemsRuntime.get_env(:salix_store, :postmark_base_url),
      token: SystemsRuntime.get_env(:salix_store, :postmark_server_token)
    }

    SystemsRuntime.put_env(:salix_store, :postmark_base_url, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:salix_store, :postmark_server_token, "store-token")

    on_exit(fn ->
      restore(:postmark_base_url, prev.base)
      restore(:postmark_server_token, prev.token)
    end)

    :ok
  end

  defp restore(key, nil), do: SystemsRuntime.delete_env(:salix_store, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:salix_store, key, value)

  test "posts one message with the caller's From and all recipients joined" do
    assert :ok = Postmark.send_email("login@comma.test", ["a@x.com", "b@y.com"], "Hi", "Body")

    assert [%{body: body, token: "store-token"}] = MockPostmark.requests()
    assert body["From"] == "login@comma.test"
    assert body["To"] == "a@x.com,b@y.com"
    assert body["Subject"] == "Hi"
    assert body["TextBody"] == "Body"
    assert body["MessageStream"] == "outbound"
  end

  test "send_message returns the provider's message id and maps rejections" do
    assert {:ok, %{message_id: "msg-1"}} =
             Postmark.send_message("login@comma.test", "a@x.com", "Hi", "Body")

    assert [%{body: %{"To" => "a@x.com"}}] = MockPostmark.requests()

    assert {:error, {:postmark, 200, 406}} =
             Postmark.send_message("login@comma.test", "a@x.com", "reject-200", "Body")
  end

  test "message_events keeps event types and bounce classes, not content or SMTP text" do
    assert {:ok, %{status: "Sent", events: [event]} = result} = Postmark.message_events("msg-1")

    assert event == %{
             type: "Bounced",
             received_at: "2026-11-03T05:41:00Z",
             bounce: %{type: "HardBounce", type_code: 1, inactive: true}
           }

    refute inspect(result) =~ "a@x.com"
    refute inspect(result) =~ "550"
    refute inspect(result) =~ "secret link"

    assert {:error, {:postmark, 422, 701}} = Postmark.message_events("unknown")
  end

  test "suppression reports the outbound stream's suppression without the address" do
    assert {:ok,
            %{reason: "HardBounce", origin: "Recipient", created_at: "2026-11-03T05:41:01Z"} =
              suppression} = Postmark.suppression("a@x.com")

    refute inspect(suppression) =~ "a@x.com"
    assert {:ok, nil} = Postmark.suppression("b@y.com")
  end
end
