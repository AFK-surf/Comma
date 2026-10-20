defmodule Mix.Tasks.Salix.Vm.CloudflarePreflightTest do
  use SystemsClock.Case, async: false

  alias Mix.Tasks.Salix.Vm.CloudflarePreflight
  alias SalixWeb.CloudVM
  alias SalixWeb.MockCloudflareGateway

  setup do
    Salix.App.configure()

    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_platform_vm = SystemsRuntime.get_env(:salix_web, :platform_vm)
    prev_req_defaults = Req.default_options()
    # The mock's 503 healthz would otherwise spend ~7s in Req's transient retries.
    Req.default_options(Keyword.put(prev_req_defaults, :retry, false))
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.delete_env(:salix_web, :platform_vm)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      CloudVM.delete_default_vm_config()
      Req.default_options(prev_req_defaults)
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
      restore_salix_web_env(:platform_vm, prev_platform_vm)
    end)

    :ok
  end

  for {name, fail_op, error_pattern, sandbox_id} <- [
        {"sandbox probe fails when disposable cleanup fails", :destroy, "destroy_failed",
         "preflight-destroy-fails"},
        {"sandbox probe fails when ensure fails", :ensure, "sandbox_probe_failed",
         "preflight-ensure-fails"},
        {"health check failure blocks preflight before sandbox probe", :healthz, "healthz_status",
         "preflight-health-fails"}
      ] do
    @fail_op fail_op
    @error_pattern error_pattern
    @sandbox_id sandbox_id

    test "#{name}" do
      gateway = start_supervised!({MockCloudflareGateway, fail_ops: [@fail_op]})
      put_cloudflare_default(gateway)

      assert_raise Mix.Error, Regex.compile!(@error_pattern), fn ->
        CloudflarePreflight.run(["--sandbox-id", @sandbox_id])
      end
    end
  end

  test "image release fence rejects a standalone Sandbox probe" do
    gateway = start_supervised!(MockCloudflareGateway)
    put_cloudflare_default(gateway)

    assert {:ok, _} =
             SalixStore.Compute.begin_cloudflare_gateway_release("preflight-release", %{})

    assert_raise Mix.Error, ~r/vm_service_upgrading/, fn ->
      CloudflarePreflight.run(["--sandbox-id", "preflight-blocked"])
    end

    refute Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :ensure))

    assert :ok =
             SalixStore.Compute.clear_cloudflare_gateway_release("preflight-release", "prepared")
  end

  defp put_cloudflare_default(gateway) do
    {:ok, _} =
      CloudVM.put_default_vm_config(%{
        "default_provider" => "cloudflare",
        "providers" => %{
          "cloudflare" => %{
            "enabled" => true,
            "gateway_base_url" => MockCloudflareGateway.base_url(gateway),
            "gateway_secret" => "test-secret"
          }
        }
      })
  end

  defp restore_salix_web_env(key, nil), do: SystemsRuntime.delete_env(:salix_web, key)
  defp restore_salix_web_env(key, value), do: SystemsRuntime.put_env(:salix_web, key, value)
end
