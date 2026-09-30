defmodule SalixWeb.CloudflareRuntimeTest do
  use ExUnit.Case, async: false
  alias SalixStore.{Compute, Ids}
  alias SalixStore.Compute, as: GroupCompute
  alias SalixWeb.CloudVM.Runtimes
  alias SalixEnv.VM.Providers.Cloudflare.{Attachments, Client}

  @tag timeout: 120_000
  test "real Go runtime uses the Cloudflare attachment for discovery, auth status and exact execution" do
    Salix.App.configure()
    home = Path.join(System.tmp_dir!(), "cf-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    binary = Path.join(home, "connector")

    {output, status} =
      System.cmd("go", ["build", "-o", binary, "."],
        cd: Path.expand("../../../connector/salix-connect", __DIR__),
        stderr_to_stdout: true
      )

    assert status == 0, output
    target = Path.join(home, ".local/share/salix/runtimes/worker-claude/bin/claude")
    File.mkdir_p!(Path.dirname(target))

    File.write!(
      target,
      "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '2.1.258 (Claude Code)'; exit 0; fi\necho '{\"loggedIn\":false}'\nexit 1\n"
    )

    File.chmod!(target, 0o700)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port_number}} = :inet.sockname(listener)
    :gen_tcp.close(listener)

    process =
      Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        args: [
          "--runtime-agent",
          "--listen",
          "127.0.0.1:#{port_number}",
          "--root",
          home,
          "--state-root",
          Path.join(home, ".state")
        ],
        env: [
          {~c"HOME", String.to_charlist(home)},
          {~c"SALIX_MANAGED_RUNTIME_ROOT",
           String.to_charlist(Path.join(home, ".local/share/salix/runtimes"))}
        ]
      ])

    {:os_pid, os_pid} = Port.info(process, :os_pid)

    on_exit(fn ->
      System.cmd("kill", [Integer.to_string(os_pid)])
      File.rm_rf!(home)
    end)

    runtime_url = "http://127.0.0.1:#{port_number}"

    eventually(fn ->
      match?({:ok, %{status: 200}}, Req.get(runtime_url <> "/readyz", retry: false))
    end)

    gateway = start_supervised!({SalixWeb.MockCloudflareGateway, runtime_url: runtime_url})

    client =
      Client.new(
        base_url: SalixWeb.MockCloudflareGateway.base_url(gateway),
        secret: "test-secret"
      )

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    device = Ids.new_device_id()
    env = "cf-runtime-#{group}"

    assert {:ok, _} =
             Attachments.ensure(
               env_id: env,
               client: client,
               sandbox_id: "native-test",
               meta: %{
                 "tenant_id" => tenant,
                 "group_id" => group,
                 "device_id" => device,
                 "connector_id" => "managed-connector"
               }
             )

    on_exit(fn -> Attachments.stop(env) end)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_name" => "native-test",
               "device_id" => device,
               "connector_id" => "managed-connector",
               "env_id" => env,
               "status" => "ready",
               "runtime_connector" => true,
               "runtime_targets" => %{
                 "worker-claude" => %{"provider" => "claude", "state" => "installed"}
               }
             })

    runtime =
      eventually(fn ->
        with {:ok, record} <- SalixEnv.Registry.get_device(tenant, group, device),
             entry when is_map(entry) <-
               Enum.find(
                 get_in(record, ["meta", "agent_runtimes"]) || [],
                 &(&1["identity_material"] == target)
               ),
             {:ok, _} <-
               SalixEnv.Control.subscription_runtime_target(
                 device,
                 entry["device_runtime_id"],
                 group,
                 tenant
               ) do
          entry
        else
          _ -> false
        end
      end)

    refute runtime["ready"]

    assert {:ok, _} =
             SalixEnv.Control.runtime_auth(:status, %{
               actor_id: "operator",
               project_id: "project",
               tenant_id: tenant,
               group_id: group,
               device_id: device,
               runtime_id: runtime["device_runtime_id"]
             })

    assert {:error, _} =
             SalixEnv.Control.subscription_runtime_target(
               device,
               runtime["device_runtime_id"],
               group,
               Ids.new_tenant_id()
             )

    assert {:ok, %{"stdout" => "cf-native-ok", "exit_code" => 0}} =
             SalixEnv.Bridge.rpc(
               env,
               SalixEnv.Protocol.request("exec", %{"command" => "printf cf-native-ok"}),
               10_000
             )

    runtime_id = runtime["device_runtime_id"]
    account = "zz-" <> SalixAgent.SubscriptionStore.id()

    {:ok, sealed} =
      SalixAgent.SubscriptionStore.seal(tenant, account, %{
        "api_key" => "cloud-runtime-test-key"
      })

    {:ok, _} =
      SalixAgent.SubscriptionStore.create(tenant, %{
        "id" => account,
        "credential_kind" => "provider_api_key",
        "provider" => "anthropic",
        "disabled" => false,
        "credentials" => sealed,
        "connection" => %{
          "endpoint" => "https://api.anthropic.com",
          "protocol" => "anthropic_messages",
          "auth_scheme" => "api_key"
        }
      })

    # Unusable early accounts must not hide a later compatible account.
    for index <- 1..3 do
      id = "00-unusable-#{index}"
      {:ok, invalid} = SalixAgent.SubscriptionStore.seal(tenant, id, %{"api_key" => ""})

      {:ok, _} =
        SalixAgent.SubscriptionStore.create(tenant, %{
          "id" => id,
          "credential_kind" => "provider_api_key",
          "provider" => "anthropic",
          "disabled" => false,
          "credentials" => invalid,
          "connection" => %{
            "endpoint" => "https://api.anthropic.com",
            "protocol" => "anthropic_messages",
            "auth_scheme" => "api_key"
          }
        })
    end

    {:ok, rec} = GroupCompute.group_workload(group)
    Runtimes.reconcile(rec, [])

    assert {:ok, %{"ready" => false, "account_binding" => nil}} =
             Runtimes.get(tenant, group, "worker-claude")

    # Installation plus an eligible tenant pool account needs no explicit bind.
    {:ok, rec} = GroupCompute.group_workload(group)
    Runtimes.reconcile(rec, [])

    eventually(fn ->
      case Runtimes.get(tenant, group, "worker-claude") do
        {:ok, %{"ready" => true}} -> true
        _ -> false
      end
    end)

    {:ok, device_record} = SalixEnv.Registry.get_device(tenant, group, device)

    {:ok, _} =
      SalixEnv.Registry.update_meta(device_record["connector_run_id"], fn meta ->
        Map.update!(meta, "agent_runtimes", fn entries ->
          Enum.map(entries, fn entry ->
            if entry["device_runtime_id"] == runtime_id,
              do: Map.put(entry, "readiness_valid_until", 1),
              else: entry
          end)
        end)
      end)

    assert {:ok, %{"ready" => false, "readiness_issue" => "readiness_expired"}} =
             Runtimes.get(tenant, group, "worker-claude")

    assert {:ok, %{account_id: ^account}} =
             SalixWeb.SubscriptionRuntimeAuth.status(
               tenant,
               group,
               device,
               runtime["device_runtime_id"]
             )

    assert {:ok, _} =
             Runtimes.unbind_account(tenant, group, "worker-claude")

    assert {:error, :not_found} =
             SalixWeb.SubscriptionRuntimeAuth.status(
               tenant,
               group,
               device,
               runtime["device_runtime_id"]
             )

    eventually(fn ->
      match?(
        {:ok, %{"ready" => false, "account_binding" => nil}},
        Runtimes.get(tenant, group, "worker-claude")
      )
    end)

    {:ok, rec} = GroupCompute.group_workload(group)
    Runtimes.reconcile(rec, [])

    assert {:error, :not_found} =
             SalixWeb.SubscriptionRuntimeAuth.status(
               tenant,
               group,
               device,
               runtime_id
             )
  end

  defp eventually(fun, attempts \\ 150)
  defp eventually(fun, 0), do: flunk("runtime did not converge: #{inspect(fun.())}")

  defp eventually(fun, attempts) do
    case fun.() do
      value when value in [false, nil] ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end
end
