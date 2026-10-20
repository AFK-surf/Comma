defmodule SalixAgent.OpenCodeConsoleTest do
  @moduledoc """
  OpenCode Go signed in with an OpenCode Console account: the device sign-in
  makes an `opencode-go` key Profile, a later sign-in to the same account
  renews it, and the key is renewed with its single-use refresh token before
  it runs out.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.AccountPool

  @day 24 * 3600 * 1000

  setup do
    tenant = SalixStore.Ids.new_tenant_id()

    {:ok, console} =
      Agent.start_link(fn -> %{approved: false, refresh: "r1", n: 1, asked: []} end)

    previous = SystemsRuntime.get_env(:salix_agent, :opencode_console)

    SystemsRuntime.put_env(:salix_agent, :opencode_console,
      base_url: "https://console.test/console",
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :opencode_console, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :opencode_console)
    end)

    Req.Test.stub(__MODULE__, &console(&1, console))
    %{tenant: tenant, console: console}
  end

  test "a Console sign-in makes one OpenCode Go key Profile, which serves with its token", c do
    profile = sign_in!(c)

    assert %{
             "credential_kind" => "provider_api_key",
             "source" => "opencode-go",
             "name" => "OpenCode Go · ada@example.test"
           } = profile

    assert {:ok, opts} =
             AccountPool.dispatch(route(c.tenant), &{:ok, &1}, fn -> false end, session_id: "s1")

    assert opts["api_key"] == "oc-access-1-0123456789abcdef"
    assert opts["default_headers"]["x-opencode-session"]

    # Signing in to the same account again renews that Profile instead of adding one.
    Agent.update(c.console, &%{&1 | approved: false})
    again = sign_in!(c)
    assert again["id"] == profile["id"]
    assert {:ok, %{"accounts" => [_one]}} = AccountPool.list(c.tenant)
  end

  test "the key is renewed with its refresh token days before it runs out, once", c do
    profile = sign_in!(c)

    # Far from running out: the key serves as it is.
    SystemsClock.advance(20 * @day)
    assert {:ok, %{"api_key" => "oc-access-1-0123456789abcdef"}} = serve(c)

    # Within three days of it: renewed, and the spent refresh token is replaced.
    SystemsClock.advance(8 * @day)
    assert {:ok, %{"api_key" => "oc-access-2-0123456789abcdef"}} = serve(c)
    assert {:ok, %{"api_key" => "oc-access-2-0123456789abcdef"}} = serve(c)
    assert Agent.get(c.console, & &1.asked) |> Enum.count(&(&1 == {:refresh, "r1"})) == 1

    assert {:ok, %{"accounts" => [%{"id" => id, "key_hint" => "…cdef"}]}} =
             AccountPool.list(c.tenant)

    assert id == profile["id"]

    # A renewal the Console refuses leaves the key as it is, and is not asked again soon.
    Agent.update(c.console, &%{&1 | refresh: "revoked"})
    SystemsClock.advance(28 * @day)
    assert {:ok, %{"api_key" => "oc-access-2-0123456789abcdef"}} = serve(c)
    assert {:ok, %{"api_key" => "oc-access-2-0123456789abcdef"}} = serve(c)
    assert Agent.get(c.console, & &1.asked) |> Enum.count(&(&1 == {:refresh, "r2"})) == 1
  end

  test "a sign-in not yet approved waits, at the Console's interval", c do
    assert {:ok, %{"id" => id, "mode" => "device", "user_code" => "ABCD-1234", "url" => url}} =
             AccountPool.begin_oauth(c.tenant, %{"provider" => "opencode-go"})

    assert url == "https://console.test/auth/device?code=ABCD-1234"

    # Asked before the interval: not passed on to the Console.
    assert {:ok, %{"status" => "pending"}} =
             AccountPool.complete_oauth(c.tenant, id, %{"code" => ""})

    refute Enum.any?(Agent.get(c.console, & &1.asked), &(&1 == :poll))

    SystemsClock.advance(5_000)

    assert {:ok, %{"status" => "pending"}} =
             AccountPool.complete_oauth(c.tenant, id, %{"code" => ""})

    assert :poll in Agent.get(c.console, & &1.asked)

    # A reconnect names no account: a Console sign-in always finds its own.
    assert {:error, _} =
             AccountPool.begin_oauth(c.tenant, %{
               "provider" => "opencode-go",
               "account_id" => "x",
               "version" => "v"
             })
  end

  defp sign_in!(c) do
    {:ok, %{"id" => id}} = AccountPool.begin_oauth(c.tenant, %{"provider" => "opencode-go"})
    Agent.update(c.console, &%{&1 | approved: true})
    SystemsClock.advance(5_000)
    {:ok, profile} = AccountPool.complete_oauth(c.tenant, id, %{"code" => ""})
    profile
  end

  defp serve(c), do: AccountPool.dispatch(route(c.tenant), &{:ok, &1}, fn -> false end, [])

  defp route(tenant) do
    {:ok, route} =
      AccountPool.resolve_config(
        %{
          "catalog_model" => "deepseek-v4.1-flash",
          "allow_paid" => true,
          "credential_scope" => "tenant"
        },
        tenant
      )

    route
  end

  # The Console: device codes, their approval, refresh tokens spent once, and the account.
  defp console(conn, state) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    form = URI.decode_query(body)

    case {conn.method, conn.request_path, form["grant_type"]} do
      {"POST", "/console/auth/device/code", _} ->
        Req.Test.json(conn, %{
          "device_code" => "dev-1",
          "user_code" => "ABCD-1234",
          "verification_uri_complete" => "/auth/device?code=ABCD-1234",
          "interval" => 5
        })

      {"POST", "/console/auth/device/token", "urn:ietf:params:oauth:grant-type:device_code"} ->
        Agent.update(state, &%{&1 | asked: &1.asked ++ [:poll]})

        if Agent.get(state, & &1.approved),
          do: Req.Test.json(conn, token(state, 1)),
          else:
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"error" => "authorization_pending"})

      {"POST", "/console/auth/device/token", "refresh_token"} ->
        refresh = form["refresh_token"]
        Agent.update(state, &%{&1 | asked: &1.asked ++ [{:refresh, refresh}]})

        if refresh == Agent.get(state, & &1.refresh),
          do: Req.Test.json(conn, token(state, Agent.get(state, & &1.n) + 1)),
          else: conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})

      {"GET", "/console/api/user", _} ->
        Req.Test.json(conn, %{"email" => "ada@example.test"})
    end
  end

  defp token(state, n) do
    Agent.update(state, &%{&1 | n: n, refresh: "r#{n}"})

    %{
      "access_token" => "oc-access-#{n}-0123456789abcdef",
      "refresh_token" => "r#{n}",
      "expires_in" => 30 * 24 * 3600
    }
  end
end
