defmodule CommaWeb.CommaReleaseTest do
  use ExUnit.Case, async: false

  setup do
    previous_secret = Application.get_env(:billing_stripe, :secret_key)
    previous_api = Application.get_env(:billing_stripe, :stripe_api)

    delete_comma_provider_prices()
    delete_bridge_default_entitlement_catalog()

    Application.put_env(:billing_stripe, :secret_key, "sk_test_release")
    Application.put_env(:billing_stripe, :stripe_api, BillingStripe.TestAPI)

    start_supervised!(%{
      id: BillingStripe.TestAPI.Recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: BillingStripe.TestAPI.Recorder]]}
    })

    on_exit(fn ->
      # These tests commit for real (`sandbox: false`), so leave the shared
      # billing test DB the way we found it — leftover comma_% price mappings
      # (digest-shaped ids from BillingStripe.TestAPI) make comma_api_test's
      # deterministic seed conflict on the NEXT `mix test` run.
      delete_comma_provider_prices()
      delete_bridge_default_entitlement_catalog()
      restore_env(:secret_key, previous_secret)
      restore_env(:stripe_api, previous_api)
    end)

    :ok
  end

  test "release sync publishes the Comma catalog to local packages and Stripe prices" do
    assert [summary] =
             with_billing_repo(fn _repo ->
               Comma.Release.sync_billing_catalog()
             end)

    assert length(summary.local.packages) == 7
    assert length(summary.local.versions) == 11
    assert length(summary.provider_prices) == 11

    lookup_keys = Comma.Billing.PricingV1.catalog().versions |> Enum.map(& &1.provider_lookup_key)

    with_billing_repo(fn repo ->
      for lookup_key <- lookup_keys do
        assert {:ok, plan} =
                 BillingCommerce.get_provider_plan(%{
                   repo: repo,
                   surface: "comma",
                   provider: "stripe",
                   provider_lookup_key: lookup_key
                 })

        assert plan.provider_price_id =~ "price_"
      end
    end)
  end

  test "release migrate catalog seeding can stay local-only without Stripe calls" do
    assert [summary] =
             with_billing_repo(fn _repo ->
               Comma.Release.sync_billing_catalog(provider_sync: false)
             end)

    assert length(summary.local.packages) == 7
    assert length(summary.local.versions) == 11
    assert summary.provider_prices == []
    assert summary.provider_sync == :skipped
    assert stripe_calls() == []
  end

  test "provider release sync starts the Stripe transport without started apps" do
    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          """
          defmodule StripeTransportProbe do
            def list_prices(_params, _opts) do
              if :ets.whereis(:hackney_pool) == :undefined do
                raise "Stripe transport pool was not started"
              end

              {:ok, %{data: []}}
            end
          end

          Application.put_env(:billing_stripe, :secret_key, "sk_test_release")
          Application.put_env(:billing_stripe, :stripe_api, StripeTransportProbe)

          [summary] =
            Comma.Release.sync_billing_provider_catalog(
              dry_run: true,
              require_provider: true
            )

          IO.puts("stripe-transport-started=\#{:ets.whereis(:hackney_pool) != :undefined}")
          IO.puts("billing-stripe-started=\#{Application.started_applications() |> Enum.any?(&(elem(&1, 0) == :billing_stripe))}")
          IO.puts("provider-plan-size=\#{length(summary.provider_plan)}")
          """
        ],
        cd: umbrella_root(),
        env: release_env(),
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "stripe-transport-started=true"
    assert output =~ "billing-stripe-started=false"
    assert output =~ "provider-plan-size=11"
  end

  @tag :tmp_dir
  test "production force_http1 config disables Hackney HTTP/2 for Stripe requests", %{
    tmp_dir: tmp_dir
  } do
    config_path = Path.join(tmp_dir, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        email: %{postmark_server_token: "release-test-postmark-token"},
        comma: %{
          database: %{url: "ecto://unused:unused@localhost/comma_unused"},
          auth: %{
            secret: "release-test-otp-secret-000000000000",
            rate_limit_secret: "release-test-rate-secret-00000000000",
            redis_url: "redis://127.0.0.1:6379/0"
          },
          email: %{from: "login@comma.test"},
          profile_avatar: %{bucket: "example-avatars"}
        },
        billing: %{
          database: %{url: "ecto://unused:unused@localhost/unused"},
          stripe: %{force_http1: true}
        }
      })
    )

    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          """
          config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
          stripe = Keyword.fetch!(config, :stripity_stripe)
          IO.inspect(Keyword.fetch!(stripe, :hackney_opts), label: "stripe-hackney-opts")
          """
        ],
        cd: umbrella_root(),
        env:
          release_env() ++
            [
              {"COMMA_SUBSYSTEMS", "comma_product"},
              {"SALIX_CONFIG_PATH", config_path}
            ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "stripe-hackney-opts: [protocols: [:http1]]"
    refute output =~ "connect_options"
    refute output =~ "ssl_options"
  end

  test "release artifact validation can load production config without a serving subsystem" do
    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          """
          config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
          comma = Keyword.fetch!(config, :comma)
          IO.inspect(Keyword.fetch!(comma, :enabled_subsystems), label: "enabled-subsystems")
          """
        ],
        cd: umbrella_root(),
        env:
          release_env() ++
            [
              {"COMMA_RELEASE_JOB", "1"},
              {"COMMA_SUBSYSTEMS", ""},
              {"REDIS_URL", nil},
              {"COMMA_REDIS_URL", nil}
            ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "enabled-subsystems: []"
  end

  @tag :tmp_dir
  test "alert-router-only runtime needs neither Redis nor another Comma subsystem", %{
    tmp_dir: tmp_dir
  } do
    config_path = Path.join(tmp_dir, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        alert_router: %{
          mode: "shadow",
          database: %{
            url: "ecto://unused:unused@localhost/alert_router_unused",
            pool_size: 6
          },
          slack: %{
            bot_token: "xoxb-alert-router-runtime-test",
            shadow_channel_id: "C-alert-router-shadow"
          },
          gcp_push: %{
            audience: "https://alerts-staging.comma.test/v1/events/gcp",
            service_account_email: "alerts@comma-staging.iam.gserviceaccount.com"
          },
          grafana_webhook: %{
            secret: "grafana-runtime-test-secret-000000000"
          },
          github_webhook: %{
            secret: "github-runtime-test-secret-0000000000"
          }
        }
      })
    )

    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          """
          config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
          alert_router = Keyword.fetch!(config, :alert_router)
          IO.inspect(get_in(config, [:comma, :enabled_subsystems]), label: "enabled-subsystems")
          IO.inspect(Keyword.fetch!(alert_router, :mode), label: "mode")
          IO.inspect(Keyword.fetch!(alert_router, :start_oban), label: "start-oban")
          IO.inspect(Keyword.fetch!(alert_router, :start_http), label: "start-http")
          IO.inspect(get_in(alert_router, [AlertRouter.Repo, :pool_size]), label: "pool-size")
          IO.inspect(get_in(alert_router, [:slack, :routes]), label: "routes")
          IO.inspect(get_in(alert_router, [:gcp_push, :oidc_provider_enabled]), label: "oidc")
          IO.puts("token-bound=" <> to_string(is_binary(get_in(alert_router, [:slack, :bot_token]))))
          """
        ],
        cd: umbrella_root(),
        env:
          release_env() ++
            [
              {"COMMA_SUBSYSTEMS", "alert_router"},
              {"COMMA_ENVIRONMENT", "staging"},
              {"SALIX_CONFIG_PATH", config_path},
              {"REDIS_URL", nil},
              {"COMMA_REDIS_URL", nil}
            ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "enabled-subsystems: [:alert_router]"
    assert output =~ "mode: :shadow"
    assert output =~ "start-oban: true"
    assert output =~ "start-http: true"
    assert output =~ "pool-size: 6"
    assert output =~ ~s(routes: %{"shadow" => "C-alert-router-shadow"})
    assert output =~ "oidc: true"
    assert output =~ "token-bound=true"
    refute output =~ "xoxb-alert-router-runtime-test"
    refute output =~ "grafana-runtime-test-secret"
    refute output =~ "github-runtime-test-secret"
  end

  @tag :tmp_dir
  test "alert router shadow mode fails closed when a provider credential is missing", %{
    tmp_dir: tmp_dir
  } do
    config_path = Path.join(tmp_dir, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        alert_router: %{
          mode: "shadow",
          database: %{url: "ecto://unused:unused@localhost/alert_router_unused"}
        }
      })
    )

    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          ~s|Config.Reader.read!("config/runtime.exs", env: :prod)|
        ],
        cd: umbrella_root(),
        env:
          release_env() ++
            [
              {"COMMA_SUBSYSTEMS", "alert_router"},
              {"SALIX_CONFIG_PATH", config_path},
              {"REDIS_URL", nil},
              {"COMMA_REDIS_URL", nil}
            ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "alert_router.slack.bot_token is required when alert_router.mode=shadow"
  end

  test "runtime binds the gateway control, proxy, routing, and mutual TLS contract together" do
    secret = String.duplicate("g", 32)

    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          """
          config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
          IO.puts("control-bound=" <> to_string(byte_size(get_in(config, [:salix_web, :agent_vmm_gateway_control_secret])) == 32))
          IO.inspect(get_in(config, [:salix_store, :agent_vmm_gateway_url_template]), label: "route")
          IO.inspect(get_in(config, [:salix_store, :agent_vmm_gateway_tls]), label: "tls")
          """
        ],
        cd: umbrella_root(),
        env:
          release_env() ++
            [
              {"COMMA_RELEASE_JOB", "1"},
              {"COMMA_SUBSYSTEMS", ""},
              {"SALIX_AGENT_VMM_GATEWAY_URL_TEMPLATE",
               "https://{instance_id}.salix-vmm-gateway-headless.comma.svc.cluster.local:8443"},
              {"SALIX_AGENT_VMM_GATEWAY_CONTROL_SECRET", secret},
              {"SALIX_AGENT_VMM_GATEWAY_CA_FILE", "/tls/ca.crt"},
              {"SALIX_AGENT_VMM_GATEWAY_CERT_FILE", "/tls/tls.crt"},
              {"SALIX_AGENT_VMM_GATEWAY_KEY_FILE", "/tls/tls.key"}
            ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "control-bound=true"
    refute output =~ secret
    assert output =~ "{instance_id}.salix-vmm-gateway-headless.comma.svc.cluster.local:8443"
    assert output =~ "verify: :verify_peer"
    assert output =~ ~s(cacertfile: ~c"/tls/ca.crt")
    assert output =~ ~s(certfile: ~c"/tls/tls.crt")
    assert output =~ ~s(keyfile: ~c"/tls/tls.key")
    assert output =~ ~s(versions: [:"tlsv1.3"])
  end

  test "aggregate release migrate supports BFT-only without Stripe config" do
    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          """
          Application.put_env(:comma, :enabled_subsystems, [:bridge_for_teams])
          Application.delete_env(:billing_stripe, :secret_key)
          :ok = Comma.Release.migrate()
          IO.puts("bft-only-migrate-ok")
          """
        ],
        cd: umbrella_root(),
        env: release_env(),
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "bft-only-migrate-ok"
  end

  test "aggregate release migrate supports alert-router-only without Billing" do
    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          """
          Application.put_env(:comma, :enabled_subsystems, [:alert_router])
          Application.put_env(:billing_core, :ecto_repos, [:billing_must_not_start])
          :ok = Comma.Release.migrate()
          IO.puts("alert-router-only-migrate-ok")
          """
        ],
        cd: umbrella_root(),
        env:
          release_env() ++
            [
              {"ALERT_ROUTER_TEST_DB_PORT", System.get_env("ALERT_ROUTER_TEST_DB_PORT", "5432")},
              {"ALERT_ROUTER_TEST_DB",
               System.get_env("ALERT_ROUTER_TEST_DB", "alert_router_test")}
            ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "alert-router-only-migrate-ok"
  end

  test "aggregate release migrate supports Comma plus Salix after the Chat hard cut" do
    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          """
          Application.put_env(:comma, :enabled_subsystems, [:comma_product, :salix])
          Application.delete_env(:billing_stripe, :secret_key)
          :ok = Comma.Release.migrate()
          IO.puts("comma-salix-migrate-ok")
          """
        ],
        cd: umbrella_root(),
        env: release_env(),
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "comma-salix-migrate-ok"
  end

  defp stripe_calls do
    BillingStripe.TestAPI.Recorder
    |> Agent.get(&Enum.reverse/1)
  end

  defp delete_comma_provider_prices do
    with_billing_repo(fn repo ->
      Ecto.Adapters.SQL.query!(
        repo,
        "DELETE FROM billing_provider_prices WHERE provider = 'stripe' AND provider_lookup_key LIKE 'comma_%'",
        []
      )
    end)
  end

  defp delete_bridge_default_entitlement_catalog do
    with_billing_repo(fn repo ->
      Ecto.Adapters.SQL.query!(
        repo,
        """
        DELETE FROM billing_manual_grants
        WHERE package_code = 'bridge_platform_unlimited'
        """,
        []
      )

      Ecto.Adapters.SQL.query!(
        repo,
        """
        DELETE FROM credit_grant_events
        WHERE credit_grant_id IN (
          SELECT id
          FROM credit_grants
          WHERE package_code = 'bridge_platform_unlimited'
             OR (source_type = 'default_entitlement' AND source_id = 'bridge_platform_unlimited')
        )
        """,
        []
      )

      Ecto.Adapters.SQL.query!(
        repo,
        """
        DELETE FROM credit_grants
        WHERE package_code = 'bridge_platform_unlimited'
           OR (source_type = 'default_entitlement' AND source_id = 'bridge_platform_unlimited')
        """,
        []
      )

      Ecto.Adapters.SQL.query!(
        repo,
        "DELETE FROM billing_package_versions WHERE package_code = 'bridge_platform_unlimited'",
        []
      )

      Ecto.Adapters.SQL.query!(
        repo,
        "DELETE FROM billing_packages WHERE code = 'bridge_platform_unlimited'",
        []
      )
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:billing_stripe, key)
  defp restore_env(key, value), do: Application.put_env(:billing_stripe, key, value)

  defp umbrella_root do
    Path.expand("../../..", __DIR__)
  end

  defp with_billing_repo(fun) do
    {:ok, _started} = Application.ensure_all_started(:billing_core)
    ensure_billing_repo_started()

    checkout_billing_repo()

    try do
      fun.(BillingCore.Repo)
    after
      Ecto.Adapters.SQL.Sandbox.checkin(BillingCore.Repo)
    end
  end

  defp checkout_billing_repo do
    Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo, sandbox: false)
  rescue
    RuntimeError ->
      restart_billing_repo()
      Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo, sandbox: false)
  catch
    :exit, _reason ->
      restart_billing_repo()
      Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo, sandbox: false)
  end

  defp ensure_billing_repo_started do
    unless Process.whereis(BillingCore.Repo) do
      case BillingCore.Repo.start_link() do
        {:ok, pid} ->
          Process.unlink(pid)
          :ok

        {:error, {:already_started, _pid}} ->
          :ok
      end
    end
  end

  defp restart_billing_repo do
    if pid = Process.whereis(BillingCore.Repo) do
      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        :exit, :noproc -> :ok
        :exit, {:noproc, _details} -> :ok
      end
    end

    ensure_billing_repo_started()
  end

  defp release_env do
    [
      {"MIX_ENV", "test"},
      {"BILLING_TEST_DB_PORT", System.get_env("BILLING_TEST_DB_PORT", "5432")},
      {"BRIDGE_TEST_DB_PORT", System.get_env("BRIDGE_TEST_DB_PORT", "5432")},
      {"REDIS_URL", System.get_env("REDIS_URL", "redis://127.0.0.1:6379/15")}
    ]
  end
end
