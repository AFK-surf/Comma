defmodule SalixStore.Compute.WorkloadCredentialTest do
  use ExUnit.Case, async: false

  alias SalixStore.Compute.WorkloadCredential

  setup do
    previous = Application.get_env(:salix_store, :compute_workload_credential_secret)

    Application.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("k", 32)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_store, :compute_workload_credential_secret, previous),
        else: Application.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    :ok
  end

  test "signed credential is exact-workload and exact-scope while public metadata stays provider-neutral" do
    assert {:ok, credential} =
             WorkloadCredential.issue("workload-1", "runtime-1", ["runtime"], 60)

    assert {:ok, claims} =
             WorkloadCredential.verify(credential["token"], "workload-1", "runtime")

    assert claims["runtime_instance_id"] == "runtime-1"
    refute Map.has_key?(claims, "provider")
    refute Map.has_key?(claims, "host")
    refute Map.has_key?(claims, "operator")
    refute Map.has_key?(credential, "claims")

    assert {:error, :invalid_workload_credential} =
             WorkloadCredential.verify(credential["token"], "workload-2", "runtime")

    assert {:error, :invalid_workload_credential} =
             WorkloadCredential.verify(credential["token"], "workload-1", "hosting")
  end

  test "tampering and unavailable signer fail closed without echoing the token" do
    assert {:ok, credential} = WorkloadCredential.issue("workload-1", nil, ["runtime"], 60)
    tampered = credential["token"] <> "x"

    result = WorkloadCredential.verify(tampered, "workload-1", "runtime")
    assert result == {:error, :invalid_workload_credential}
    refute inspect(result) =~ credential["token"]

    Application.delete_env(:salix_store, :compute_workload_credential_secret)

    assert {:error, :credential_signer_unavailable} =
             WorkloadCredential.issue("workload-1", nil, ["runtime"], 60)
  end
end
