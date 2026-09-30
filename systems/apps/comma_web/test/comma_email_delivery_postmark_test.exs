defmodule CommaWeb.EmailDeliveryPostmarkTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Comma.AuthChallengeStore.Redis
  alias Comma.EmailDelivery.Postmark

  @redis_url System.get_env("COMMA_TEST_REDIS_URL", "redis://127.0.0.1:6379/0")
  @router_opts CommaWeb.Router.init([])

  defmodule MockPostmark do
    @behaviour Plug
    import Plug.Conn

    def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def requests, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", request_path: "/email"} = conn, _opts) do
      {:ok, raw_body, conn} = read_body(conn)
      body = Jason.decode!(raw_body)
      token = conn |> get_req_header("x-postmark-server-token") |> List.first()
      Agent.update(__MODULE__, &[%{body: body, token: token} | &1])

      {status, response} = response_for(body["To"])

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")

    defp response_for("inactive-200@example.com"), do: {200, %{"ErrorCode" => 406}}
    defp response_for("inactive-401@example.com"), do: {401, %{"ErrorCode" => 406}}
    defp response_for("inactive-503@example.com"), do: {503, %{"ErrorCode" => 406}}
    defp response_for("inactive-other@example.com"), do: {418, %{"ErrorCode" => 406}}
    defp response_for("inactive-" <> _rest), do: {422, %{"ErrorCode" => 406}}
    defp response_for("provider-503-406-" <> _rest), do: {503, %{"ErrorCode" => 406}}
    defp response_for("invalid-request@example.com"), do: {422, %{"ErrorCode" => 300}}
    defp response_for("unauthorized@example.com"), do: {401, %{"ErrorCode" => 10}}
    defp response_for("unknown-error@example.com"), do: {418, %{"ErrorCode" => 9999}}
    defp response_for("unavailable-" <> _rest), do: {503, %{"ErrorCode" => 0}}
    defp response_for("unavailable@example.com"), do: {503, %{"ErrorCode" => 0}}

    defp response_for(recipient) do
      if String.contains?(recipient, "..") or String.contains?(recipient, "?") do
        {422, %{"ErrorCode" => 300}}
      else
        {200, %{"ErrorCode" => 0}}
      end
    end
  end

  setup do
    start_supervised!(MockPostmark)

    port =
      Enum.find_value(1..10, fn _attempt ->
        candidate = 40_000 + :erlang.phash2(make_ref(), 20_000)

        case start_supervised(
               {Bandit, plug: MockPostmark, port: candidate},
               id: {:comma_postmark_bandit, candidate}
             ) do
          {:ok, _pid} -> candidate
          {:error, _reason} -> nil
        end
      end)

    assert is_integer(port)

    previous = %{
      base_url: Application.get_env(:salix_store, :postmark_base_url),
      token: Application.get_env(:salix_store, :postmark_server_token),
      mail: Application.get_env(:comma_core, :mail),
      auth: Application.get_env(:comma_core, :auth)
    }

    Application.put_env(:salix_store, :postmark_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_store, :postmark_server_token, "comma-postmark-token")
    Application.put_env(:comma_core, :mail, from: "login@comma.test")

    on_exit(fn ->
      restore_env(:salix_store, :postmark_base_url, previous.base_url)
      restore_env(:salix_store, :postmark_server_token, previous.token)
      restore_env(:comma_core, :mail, previous.mail)
      restore_env(:comma_core, :auth, previous.auth)
      Comma.AuthChallengeStore.Memory.reset!()
    end)

    :ok
  end

  test "sends distinct login and Google-link OTP messages through the shared Postmark adapter" do
    assert :ok = Postmark.send_login_code("person@example.com", "123456", %{})

    assert :ok =
             Postmark.send_login_code("link@example.com", "654321", %{purpose: "google_link"})

    assert [
             %{token: "comma-postmark-token", body: login_body},
             %{token: "comma-postmark-token", body: link_body}
           ] = MockPostmark.requests()

    assert login_body["From"] == "login@comma.test"
    assert login_body["To"] == "person@example.com"
    assert login_body["Subject"] == "Your Comma login code"
    assert login_body["TextBody"] =~ "login verification code is 123456"
    assert login_body["MessageStream"] == "outbound"
    assert login_body["HtmlBody"] =~ "123456"
    origin = Application.fetch_env!(:comma_web, :web_cookie_origin)
    assert login_body["HtmlBody"] =~ ~s(src="#{origin}/brand/comma/icon.png")
    assert Map.get(login_body, "Attachments", []) == []
    assert Map.get(link_body, "Attachments", []) == []

    assert link_body["From"] == "login@comma.test"
    assert link_body["To"] == "link@example.com"
    assert link_body["Subject"] == "Confirm your Google account link"
    assert link_body["TextBody"] =~ "Google account linking code is 654321"
    assert link_body["TextBody"] =~ "only if you started linking Google"
    assert link_body["MessageStream"] == "outbound"
    assert link_body["HtmlBody"] =~ "654321"
    assert link_body["HtmlBody"] =~ "only if you started linking Google"
  end

  test "classifies recipient rejection separately and fails unknown or provider-wide errors closed" do
    assert {:error, :recipient_rejected} =
             Postmark.send_login_code("inactive-direct@example.com", "111111", %{})

    assert {:error, :provider_unavailable} =
             Postmark.send_login_code("inactive-200@example.com", "111112", %{})

    assert {:error, :provider_unavailable} =
             Postmark.send_login_code("inactive-401@example.com", "111113", %{})

    assert {:error, :provider_unavailable} =
             Postmark.send_login_code("inactive-503@example.com", "111114", %{})

    assert {:error, :provider_unavailable} =
             Postmark.send_login_code("inactive-other@example.com", "111115", %{})

    assert {:error, :provider_unavailable} =
             Postmark.send_login_code("invalid-request@example.com", "222222", %{})

    assert {:error, :provider_unavailable} =
             Postmark.send_login_code("unauthorized@example.com", "333333", %{})

    assert {:error, :provider_unavailable} =
             Postmark.send_login_code("unknown-error@example.com", "444444", %{})

    assert {:error, :provider_unavailable} =
             Postmark.send_login_code("unavailable@example.com", "555555", %{})

    assert Enum.count(MockPostmark.requests(), &(&1.body["To"] == "unavailable@example.com")) ==
             1
  end

  test "rejects Postmark-invalid recipients before delivery without opening the Redis circuit" do
    prefix =
      "comma:test:postmark-invalid-recipient:#{System.unique_integer([:positive, :monotonic])}"

    Application.put_env(:comma_core, :auth,
      challenge_store: Redis,
      email_delivery: Postmark,
      secret: "postmark-invalid-recipient-auth-secret",
      rate_limit_secret: "postmark-invalid-recipient-rate-secret",
      redis_url: @redis_url,
      redis_key_prefix: prefix,
      resend_cooldown_seconds: 0,
      email_request_limit: 100,
      ip_request_limit: 100,
      provider_failure_threshold: 1,
      provider_failure_window_seconds: 60,
      provider_circuit_open_seconds: 60,
      expose_codes: false
    )

    start_supervised!({Redix, {@redis_url, [name: Redis.connection_name(), sync_connect: true]}})
    on_exit(fn -> delete_redis_keys(prefix) end)

    invalid_recipients =
      Enum.map(1..5, &"invalid-#{&1}..recipient@example.com") ++
        Enum.map(1..5, &"invalid-question-#{&1}?@example.com")

    for recipient <- invalid_recipients do
      rejected = request_email_login(recipient)
      assert rejected.status == 400
      assert Jason.decode!(rejected.resp_body) == %{"error" => "invalid_email"}
      assert get_resp_header(rejected, "retry-after") == []
    end

    accepted = request_email_login("still-valid@example.com")
    assert accepted.status == 200
    assert get_resp_header(accepted, "retry-after") == []
    assert %{"challenge_id" => challenge_id} = Jason.decode!(accepted.resp_body)
    assert is_binary(challenge_id)

    assert [%{body: %{"To" => "still-valid@example.com"}}] = MockPostmark.requests()
  end

  test "recipient rejections bypass and 503/406 failures open the shared Redis circuit" do
    prefix = "comma:test:postmark-circuit:#{System.unique_integer([:positive, :monotonic])}"

    Application.put_env(:comma_core, :auth,
      challenge_store: Redis,
      email_delivery: Postmark,
      secret: "postmark-circuit-auth-secret",
      rate_limit_secret: "postmark-circuit-rate-secret",
      redis_url: @redis_url,
      redis_key_prefix: prefix,
      resend_cooldown_seconds: 0,
      email_request_limit: 100,
      ip_request_limit: 100,
      provider_failure_threshold: 5,
      provider_failure_window_seconds: 60,
      provider_circuit_open_seconds: 60,
      expose_codes: false
    )

    start_supervised!({Redix, {@redis_url, [name: Redis.connection_name(), sync_connect: true]}})
    on_exit(fn -> delete_redis_keys(prefix) end)

    for index <- 1..5 do
      rejected = request_email_login("inactive-#{index}@example.com")
      assert rejected.status == 503
      assert Jason.decode!(rejected.resp_body) == %{"error" => "email_delivery_unavailable"}
      assert get_resp_header(rejected, "retry-after") == []
    end

    accepted = request_email_login("accepted@example.com")
    assert accepted.status == 200
    assert %{"challenge_id" => challenge_id} = Jason.decode!(accepted.resp_body)
    assert is_binary(challenge_id)

    for index <- 1..5 do
      unavailable = request_email_login("provider-503-406-#{index}@example.com")
      assert unavailable.status == 503
      assert Jason.decode!(unavailable.resp_body) == %{"error" => "email_delivery_unavailable"}
    end

    blocked = request_email_login("blocked-valid@example.com")
    assert blocked.status == 503
    assert Jason.decode!(blocked.resp_body) == %{"error" => "email_delivery_unavailable"}
    assert [_retry_after] = get_resp_header(blocked, "retry-after")

    requests = MockPostmark.requests()
    assert Enum.count(requests, &String.starts_with?(&1.body["To"], "inactive-")) == 5
    assert Enum.count(requests, &(&1.body["To"] == "accepted@example.com")) == 1
    assert Enum.count(requests, &String.starts_with?(&1.body["To"], "provider-503-406-")) == 5
    refute Enum.any?(requests, &(&1.body["To"] == "blocked-valid@example.com"))
  end

  test "auth telemetry reports the production provider with bounded labels" do
    Application.put_env(:comma_core, :auth,
      challenge_store: Comma.AuthChallengeStore.Memory,
      email_delivery: Comma.EmailDelivery.Postmark,
      secret: "postmark-telemetry-auth-secret",
      rate_limit_secret: "postmark-telemetry-rate-secret",
      resend_cooldown_seconds: 0,
      email_request_limit: 100,
      ip_request_limit: 100,
      provider_failure_threshold: 100,
      expose_codes: false
    )

    Comma.AuthChallengeStore.Memory.reset!()
    handler_id = "comma-postmark-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:comma_product, :operation, :stop],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{"challenge_id" => challenge_id}} =
             Comma.AuthChallenges.request_email_login(%{
               "email" => "telemetry-postmark@example.com",
               "remote_ip" => "203.0.113.20"
             })

    metadata =
      1..3
      |> Enum.map(fn _index ->
        assert_receive {:postmark_telemetry, event_metadata}
        event_metadata
      end)
      |> Enum.find(&(&1.operation == :postmark_delivery))

    assert metadata == %{operation: :postmark_delivery, provider: "postmark", outcome: :ok}
    refute inspect(metadata) =~ "telemetry-postmark@example.com"
    refute inspect(metadata) =~ challenge_id
  end

  def handle_telemetry(_event, _measurements, metadata, pid) do
    send(pid, {:postmark_telemetry, metadata})
  end

  defp request_email_login(email) do
    :post
    |> conn("/v1/comma/auth/email/login", Jason.encode!(%{"email" => email}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-comma-session-transport", "bearer")
    |> CommaWeb.Router.call(@router_opts)
  end

  defp delete_redis_keys(prefix) do
    {:ok, connection} = Redix.start_link(@redis_url)

    try do
      case scan_redis_keys(connection, prefix) do
        [] -> :ok
        keys -> Redix.command(connection, ["UNLINK" | keys])
      end
    after
      GenServer.stop(connection)
    end
  end

  defp scan_redis_keys(connection, prefix, cursor \\ "0", acc \\ []) do
    {:ok, [next_cursor, keys]} =
      Redix.command(connection, ["SCAN", cursor, "MATCH", "#{prefix}:*", "COUNT", "100"])

    acc = keys ++ acc
    if next_cursor == "0", do: acc, else: scan_redis_keys(connection, prefix, next_cursor, acc)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
