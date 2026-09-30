defmodule SalixEnv.VM.Providers.CloudflareTest do
  use ExUnit.Case, async: false

  alias SalixEnv.Bridge
  alias SalixWeb.ComputeProviders.Cloudflare
  alias SalixEnv.VM.Providers.Cloudflare.{Attachments, Client, MockConnectGateway}

  setup do
    gateway = start_supervised!(MockConnectGateway)
    client = Client.new(base_url: MockConnectGateway.base_url(gateway), secret: "test-secret")

    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    rec = %{
      "env_id" => "cloudflare-env-#{System.unique_integer([:positive])}",
      "provider_resource_id" => "sb-1",
      "provider_resource_name" => "sb-1",
      "provider" => "cloudflare",
      "provider_spec" => %{"profile_key" => "cf-standard-2"},
      "status" => "ready",
      "tenant_id" => tenant,
      "group_id" => group,
      "device_id" => SalixStore.Ids.new_device_id(),
      "connector_id" => "conn-cloudflare-test",
      "alias" => "cloud-vm",
      "name" => "Cloud VM"
    }

    {:ok, _, :created} = SalixStore.Compute.ensure_group_workload(rec)

    on_exit(fn -> Attachments.stop(rec["env_id"]) end)

    %{gateway: gateway, client: client, rec: rec}
  end

  test "ensure wakes sandbox, checks connector readiness, and starts attachment", %{
    gateway: gateway,
    client: client,
    rec: rec
  } do
    assert {:ok, %{sandbox: %{"status" => "ready"}, attachment: pid}} =
             Cloudflare.ensure(rec, rec, client: client)

    assert Process.alive?(pid)
    assert wait_until(fn -> Bridge.local?(rec["env_id"]) end)

    assert {:ok, _} = MockConnectGateway.wait_for_frame(gateway, &(&1["http_op"] == "ensure"))
    assert {:ok, _} = MockConnectGateway.wait_for_frame(gateway, &(&1["http_op"] == "readyz"))
  end

  test "Compute bootstrap attaches the exact device and carries commands beyond readiness", %{
    client: client,
    rec: rec,
    gateway: gateway
  } do
    {:ok, stored} = SalixStore.Compute.group_workload(rec["group_id"])

    workload = SalixStore.Repo.get!(SalixStore.Compute.Workload, stored["workload_id"])
    allocation = SalixStore.Repo.get!(SalixStore.Compute.Allocation, stored["allocation_id"])

    {:ok, credential} =
      SalixStore.Compute.WorkloadCredential.issue(workload.id, nil, ["runtime"], 60)

    assert {:ok, %{outcome: :succeeded}} =
             Cloudflare.allocate(allocation, workload, client: client)

    assert {:ok, %{outcome: :succeeded, attachment: pid}} =
             Cloudflare.bootstrap(allocation, workload, credential, client: client)

    assert Process.alive?(pid)
    assert wait_until(fn -> Bridge.local?(rec["env_id"]) end)

    assert {:ok, %{"stdout" => "ok", "exit_code" => 0}} =
             Bridge.rpc(
               rec["env_id"],
               %{
                 "type" => "request",
                 "id" => "cf-compute-exec",
                 "method" => "exec",
                 "params" => %{"command" => "echo routed"}
               },
               2_000
             )

    assert {:ok, _} = MockConnectGateway.wait_for_frame(gateway, &(&1["id"] == "cf-compute-exec"))

    assert {:error, :invalid_workload_credential} =
             Cloudflare.bootstrap(allocation, %{workload | id: "other"}, credential,
               client: client
             )
  end

  test "destroy stops local attachment before deleting sandbox", %{client: client, rec: rec} do
    assert {:ok, %{attachment: pid}} =
             Cloudflare.ensure(rec, rec, client: client)

    assert wait_until(fn -> Bridge.local?(rec["env_id"]) end)

    assert :ok = Cloudflare.destroy(rec, client: client)
    refute wait_until(fn -> Process.alive?(pid) end, 200)
  end

  defp wait_until(fun, remaining_ms \\ 2_000)
  defp wait_until(_fun, remaining_ms) when remaining_ms <= 0, do: false

  defp wait_until(fun, remaining_ms) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, remaining_ms - 20)
    end
  end
end
