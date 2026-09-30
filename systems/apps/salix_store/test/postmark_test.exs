defmodule SalixStore.PostmarkTest do
  @moduledoc """
  `SalixStore.Postmark` against a Bandit mock of the Postmark /email endpoint:
  request shape (From per caller, joined To, server token header), success and
  failure mapping, and the not-configured guard.
  """
  use ExUnit.Case, async: false

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
          _ -> {200, %{"ErrorCode" => 0, "Message" => "OK"}}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(resp))
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  setup do
    start_supervised!(MockPostmark)

    port =
      Enum.find_value(1..10, fn _ ->
        p = 40000 + :erlang.phash2(make_ref(), 20000)

        case start_supervised({Bandit, plug: MockPostmark, port: p}, id: {:bandit, p}) do
          {:ok, _pid} -> p
          {:error, _} -> nil
        end
      end)

    prev = %{
      base: Application.get_env(:salix_store, :postmark_base_url),
      token: Application.get_env(:salix_store, :postmark_server_token)
    }

    Application.put_env(:salix_store, :postmark_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_store, :postmark_server_token, "store-token")

    on_exit(fn ->
      restore(:postmark_base_url, prev.base)
      restore(:postmark_server_token, prev.token)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:salix_store, key)
  defp restore(key, value), do: Application.put_env(:salix_store, key, value)

  test "posts one message with the caller's From and all recipients joined" do
    assert :ok = Postmark.send_email("login@comma.test", ["a@x.com", "b@y.com"], "Hi", "Body")

    assert [%{body: body, token: "store-token"}] = MockPostmark.requests()
    assert body["From"] == "login@comma.test"
    assert body["To"] == "a@x.com,b@y.com"
    assert body["Subject"] == "Hi"
    assert body["TextBody"] == "Body"
    assert body["MessageStream"] == "outbound"
  end

  test "splits recipient lists past Postmark's 50-per-message cap" do
    recipients = for i <- 1..51, do: "user#{i}@example.com"

    assert :ok = Postmark.send_email("login@comma.test", recipients, "Hi", "Body")

    assert [first, second] = MockPostmark.requests()
    assert length(String.split(first.body["To"], ",")) == 50
    assert second.body["To"] == "user51@example.com"
  end

  test "maps HTTP and in-body Postmark errors without echoing recipients" do
    assert {:error, {:postmark, 422, 300}} =
             Postmark.send_email("f@x.com", ["a@x.com"], "reject-422", "b")

    assert {:error, {:postmark, 200, 406}} =
             Postmark.send_email("f@x.com", ["a@x.com"], "reject-200", "b")
  end

  test "requires the server token and a From address" do
    Application.put_env(:salix_store, :postmark_server_token, "")
    assert {:error, :not_configured} = Postmark.send_email("f@x.com", ["a@x.com"], "s", "b")
    refute Postmark.configured?()

    Application.put_env(:salix_store, :postmark_server_token, "store-token")
    assert Postmark.configured?()
    assert {:error, :not_configured} = Postmark.send_email("  ", ["a@x.com"], "s", "b")
    assert MockPostmark.requests() == []
  end
end
