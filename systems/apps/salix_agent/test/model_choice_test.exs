defmodule SalixAgent.ModelChoiceTest do
  @moduledoc "The check a Router's model choice passes before a Session stores it."
  use SystemsClock.Case, async: false

  alias SalixAgent.{AccountPool, ModelChoice}
  alias SalixStore.S3

  setup do
    start_supervised!(S3.Fake)
    %{tenant: SalixAgent.TestSupport.new_tenant_id()}
  end

  test "a catalog model with one of its efforts is stored without unset fields", %{tenant: tenant} do
    assert {:ok,
            %{"kind" => "catalog", "model" => "gpt-5.5", "reasoning_effort" => "high"} = value} =
             ModelChoice.choose(
               %{"kind" => "catalog", "model" => "gpt-5.5", "reasoning_effort" => "high"},
               tenant
             )

    assert value["allow_paid"] == false
    refute Map.has_key?(value, "profile_id")
  end

  test "pinning an API-key Profile is choosing to pay for it", %{tenant: tenant} do
    {:ok, profile} =
      AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "source" => "openrouter",
        "api_key" => "sk-or-v1-0123456789abcdef"
      })

    assert {:ok, %{"allow_paid" => true, "profile_id" => id}} =
             ModelChoice.choose(
               %{"kind" => "catalog", "model" => "gpt-5.5", "profile_id" => profile["id"]},
               tenant
             )

    assert id == profile["id"]
  end
end
