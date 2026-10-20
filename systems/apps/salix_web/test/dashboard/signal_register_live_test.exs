defmodule SalixWeb.Dashboard.SignalRegisterLiveTest do
  @moduledoc """
  The Signal registration page (docs/messaging-voice.md) against the fake
  chat service of the salix_signal tests (written from CRS-02 §2 and §3),
  reached over HTTPS through the page's transport option. It covers the
  operator flow from the verification session to a usable account, the
  resume of an account left `registering`, and the message of each failure.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixSignal.Service.Response
  alias SalixSignal.Test.{FakeAccountService, FakeChat}

  @endpoint SalixWeb.DashboardEndpoint
  @wait 60_000

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    previous_kem = SystemsRuntime.get_env(:salix_signal_proto, :plain_kem_in_tests)
    previous = SystemsRuntime.get_env(:salix_web, :signal_registration)

    # This host's OpenSSL has no ML-KEM; test builds may make KEM keys in
    # plain Elixir (SalixSignalProto.KemBackend).
    SystemsRuntime.put_env(:salix_signal_proto, :plain_kem_in_tests, true)

    {:ok, fake} = FakeAccountService.start_link()
    server = start_supervised!({Bandit, FakeAccountService.bandit_options(fake, chain)})
    base = {:http, "https://localhost:#{FakeChat.port(server)}", roots: [chain.root]}

    # One-shot answers that replace the fake's answer to a matching request.
    {:ok, overrides} = Agent.start_link(fn -> [] end)
    test = SystemsRuntime.Proc.self()

    transport = fn _environment ->
      fn method, path, opts ->
        case take_override(overrides, method, path) do
          nil -> SalixSignal.Account.Transport.request(base, method, path, opts)
          response -> {:ok, response}
        end
      end
    end

    SystemsRuntime.put_env(:salix_web, :signal_registration,
      transport: transport,
      start: fn id ->
        SystemsRuntime.Proc.send(test, {:owner_started, id})
        {:ok, SystemsRuntime.Proc.self()}
      end
    )

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Signal Register"})

    number =
      "+1555010" <>
        String.pad_leading(Integer.to_string(SystemsRuntime.Proc.uniform(9_999)), 4, "0")

    on_exit(fn ->
      restore(:salix_web, :signal_registration, previous)
      restore(:salix_signal_proto, :plain_kem_in_tests, previous_kem)
      _ = SalixSignal.Settings.set_platform_number(nil)

      {:ok, accounts} = SalixSignal.Accounts.list_by_number(number)

      for %{id: id} <- accounts,
          do:
            SalixStore.Repo.query!("DELETE FROM signal_accounts WHERE id = $1", [
              Ecto.UUID.dump!(id)
            ])
    end)

    %{fake: fake, overrides: overrides, number: number, tenant_id: tenant["tenant_id"]}
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp take_override(overrides, method, path) do
    Agent.get_and_update(overrides, fn list ->
      case Enum.split_with(list, fn {m, suffix, _fun} ->
             m == method and String.ends_with?(path, suffix)
           end) do
        {[{_, _, fun} | rest], others} -> {fun.(path), rest ++ others}
        {[], _} -> {nil, list}
      end
    end)
  end

  defp override(ctx, method, suffix, fun),
    do: Agent.update(ctx.overrides, &(&1 ++ [{method, suffix, fun}]))

  defp json(status, body, headers \\ []),
    do: %Response{
      status: status,
      headers: headers,
      body: if(body, do: Jason.encode!(body), else: "")
    }

  defp conn(ctx),
    do:
      Plug.Test.init_test_session(build_conn(), %{
        "admin_authed" => true,
        "current_tenant" => ctx.tenant_id
      })

  defp start(view, ctx, fields \\ %{}) do
    view
    |> form(
      "#signal-register-start",
      Map.merge(
        %{"number" => ctx.number, "environment" => "staging", "scope" => "platform"},
        fields
      )
    )
    |> render_submit()

    render_async(view, @wait)
  end

  defp captcha(view, value) do
    view |> form("#signal-register-captcha", %{"captcha" => value}) |> render_submit()
    render_async(view, @wait)
  end

  defp request_sms(view) do
    view |> element("#signal-request-sms") |> render_click()
    render_async(view, @wait)
  end

  # A correct code verifies the session, and the page registers at once:
  # two steps, each in its own async task.
  defp code(view, value) do
    view |> form("#signal-register-code", %{"code" => value}) |> render_submit()
    render_async(view, @wait)
    render_async(view, @wait)
  end

  defp verify(view) do
    captcha(view, "signalcaptcha://" <> FakeAccountService.captcha())
    request_sms(view)
    code(view, FakeAccountService.code())
  end

  defp accounts(number) do
    {:ok, accounts} = SalixSignal.Accounts.list_by_number(number)
    accounts
  end

  test "an operator registers a number step by step and can use it at once", ctx do
    {:ok, signal, html} = live(conn(ctx), "/dash/signal")
    assert html =~ ~s(href="/dash/signal/register")

    {:ok, view, _html} =
      signal |> element("#signal-register-link") |> render_click() |> follow_redirect(conn(ctx))

    html = start(view, ctx)
    assert html =~ "Still required"
    assert html =~ "captcha"
    assert html =~ "https://signalcaptchas.org/staging/registration/generate.html"

    html = captcha(view, "signalcaptcha://signal-hcaptcha.SITE.registration.BAD")
    assert html =~ "The captcha was rejected. Solve a new captcha and paste the new link."

    html = captcha(view, "signalcaptcha://" <> FakeAccountService.captcha())
    refute html =~ "The captcha was rejected"
    assert html =~ "Send code by SMS (now)"
    assert html =~ "Send code by voice call (in 60 s, at "

    html = request_sms(view)
    assert html =~ "signal-register-code"

    html = code(view, "000000")
    assert html =~ "The code is wrong. Check it and enter it again."
    assert accounts(ctx.number) == []

    html = code(view, FakeAccountService.code())
    assert html =~ "Registered"

    assert [%{id: id, state: :active, scope: :platform, environment: :staging}] =
             accounts(ctx.number)

    assert html =~ id
    assert html =~ "active"
    assert_received {:owner_started, ^id}

    # Nothing secret reaches the page.
    refute html =~ FakeAccountService.captcha()
    refute html =~ FakeAccountService.code()

    # The new account is listed and can serve as the platform number.
    {:ok, _signal, html} = live(conn(ctx), "/dash/signal")
    assert html =~ ctx.number
    assert {:ok, %{"account_id" => ^id}} = SalixSignal.Settings.set_platform_number(ctx.number)

    # A second registration of an active number would sign it out.
    {:ok, view, _html} = live(conn(ctx), "/dash/signal/register")
    html = start(view, ctx)
    assert html =~ "already has an active account in this environment"
    assert length(accounts(ctx.number)) == 1
  end

  test "a failed registration is resumed with its stored keys, not duplicated", ctx do
    {:ok, view, _html} = live(conn(ctx), "/dash/signal/register")
    org = %{"scope" => "organization", "tenant_id" => ctx.tenant_id}

    html = start(view, ctx, %{"scope" => "organization", "tenant_id" => "unknown-tenant"})
    assert html =~ "No tenant has this ID."

    start(view, ctx, org)
    override(ctx, "POST", "/v1/registration", fn _path -> json(503, nil) end)
    html = verify(view)
    assert html =~ "The Signal service is unavailable. Try again later."
    assert html =~ "Retry registration"
    assert [%{id: id, state: :registering}] = accounts(ctx.number)

    # The operator starts over with a new session; the stored account is
    # resumed, and its owner must match.
    view |> element("button", "Start over") |> render_click()
    html = start(view, ctx)
    assert html =~ "is stored with owner tenant #{ctx.tenant_id}. Choose that owner to resume it."

    html = start(view, ctx, org)
    assert html =~ "A failed registration of this number is stored (account #{id})"

    html = verify(view)
    assert html =~ "Registered"
    assert html =~ id
    assert_received {:owner_started, ^id}

    assert [%{id: ^id, state: :active, scope: {:organization, tenant_id}}] = accounts(ctx.number)
    assert tenant_id == ctx.tenant_id
  end
end
