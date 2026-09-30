defmodule SalixWeb.AgentVMMInstallationControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias SalixStore.{AgentVMMInstallations, Compute, Repo}
  alias SalixStore.AgentVMMInstallMaterialFixtures

  @p256_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @control_secret String.duplicate("control-", 4)
  @root_public_key :binary.copy(<<4>>, 33)

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_install_operations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    {:ok, pool} = Compute.ensure_managed_default_pool("tenant", "agent_vmm")

    {:ok, _environment} =
      Compute.create_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    previous = Application.get_env(:salix_store, :agent_vmm_install_material)
    previous_control = Application.get_env(:salix_web, :agent_vmm_gateway_control_secret)
    previous_receipt = Application.get_env(:salix_store, :personal_mesh_registry_receipt_signer)
    previous_managed = Application.get_env(:salix_store, :agent_vmm_managed_trust_signing)

    Application.put_env(
      :salix_store,
      :agent_vmm_install_material,
      AgentVMMInstallMaterialFixtures.catalog()
    )

    Application.put_env(:salix_web, :agent_vmm_gateway_control_secret, @control_secret)
    {_receipt_public, receipt_private} = keypair()

    Application.put_env(:salix_store, :personal_mesh_registry_receipt_signer, fn payload ->
      {"registry-key", sign(payload, receipt_private)}
    end)

    {managed_public, managed_private} = keypair()

    Application.put_env(:salix_store, :agent_vmm_managed_trust_signing, %{
      authority_prefix: "salix-managed",
      key_id: "managed-key",
      key_revision: 1,
      public_key: compress_public_key(managed_public),
      signer: &sign(&1, managed_private)
    })

    on_exit(fn ->
      put_or_delete(:salix_store, :agent_vmm_install_material, previous)
      put_or_delete(:salix_web, :agent_vmm_gateway_control_secret, previous_control)
      put_or_delete(:salix_store, :personal_mesh_registry_receipt_signer, previous_receipt)
      put_or_delete(:salix_store, :agent_vmm_managed_trust_signing, previous_managed)
    end)

    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())
    {:ok, descriptor: descriptor}
  end

  test "exchange and ACK use only InstallOperation auth and clear recoverable material", ctx do
    response = exchange(ctx.descriptor)
    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]

    body = Jason.decode!(response.resp_body)
    assert body["operation_id"] == ctx.descriptor.operation.id
    assert body["registration_id"] == ctx.descriptor.operation.registration_id
    refute body["remote_enrollment"]["enrollment_token"] == ""

    recovered = exchange(ctx.descriptor) |> then(&Jason.decode!(&1.resp_body))
    assert recovered == body

    ack =
      request(
        "/v1/compute/agent-vmm/install-operations/ack",
        %{
          "operation_id" => ctx.descriptor.operation.id,
          "host_identity_digest" => body["host_identity_digest"]
        },
        ctx.descriptor.one_time_secret
      )

    assert ack.status == 200
    assert Jason.decode!(ack.resp_body)["operation"]["authorization_status"] == "handed_off"

    assert request(
             "/v1/compute/agent-vmm/install-operations/ack",
             %{
               "operation_id" => ctx.descriptor.operation.id,
               "host_identity_digest" => body["host_identity_digest"]
             },
             ctx.descriptor.one_time_secret
           ).status == 200
  end

  test "malformed schemes, wrong tickets, Host mismatch, and client material fields fail closed",
       ctx do
    path = "/v1/compute/agent-vmm/install-operations/exchange"
    body = exchange_body(ctx.descriptor.operation.id)

    unauthorized =
      conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> ctx.descriptor.one_time_secret)
      |> SalixWeb.Router.call(SalixWeb.Router.init([]))

    assert unauthorized.status == 401
    assert get_resp_header(unauthorized, "cache-control") == ["no-store"]
    assert request(path, body, "vmmi_wrong").status == 401

    assert request(path, Map.put(body, "version", 1), ctx.descriptor.one_time_secret).status ==
             400

    assert request(
             path,
             Map.put(body, "artifact_url", "https://evil.test/host.zip"),
             ctx.descriptor.one_time_secret
           ).status == 400

    mismatched = Map.put(body, "device_id", "other-host")
    assert request(path, mismatched, ctx.descriptor.one_time_secret).status == 200
    assert request(path, body, ctx.descriptor.one_time_secret).status == 409
  end

  test "install-operation bodies are bounded before JSON parsing", ctx do
    oversized = Jason.encode!(%{"padding" => String.duplicate("x", 20_000)})

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      conn(:post, "/v1/compute/agent-vmm/install-operations/exchange", oversized)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "InstallOperation " <> ctx.descriptor.one_time_secret)
      |> SalixWeb.Router.call(SalixWeb.Router.init([]))
    end
  end

  test "fresh operation converges through handoff, managed enrollment, and current admission",
       ctx do
    exchanged = exchange(ctx.descriptor)
    assert exchanged.status == 200
    material = Jason.decode!(exchanged.resp_body)

    assert request(
             "/v1/compute/agent-vmm/install-operations/ack",
             %{
               "operation_id" => ctx.descriptor.operation.id,
               "host_identity_digest" => material["host_identity_digest"]
             },
             ctx.descriptor.one_time_secret
           ).status == 200

    enrollment = %{
      "protocolVersion" => "remote.v1",
      "registrationId" => material["registration_id"],
      "enrollmentToken" => material["remote_enrollment"]["enrollment_token"],
      "supportedFeatures" => ["session-v1"],
      "deviceIdentity" => %{
        "deviceId" => "host-device",
        "rootPublicKey" => Base.encode64(@root_public_key),
        "rootKeyRevision" => "1",
        "signatureSuite" => "SIGNATURE_SUITE_P256_SHA256"
      }
    }

    enrolled = gateway_request("/v1/compute/enroll", %{"request_b64" => encode_json(enrollment)})
    assert enrolled.status == 200

    credential =
      enrolled.resp_body
      |> Jason.decode!()
      |> Map.fetch!("response_b64")
      |> Base.decode64!()
      |> Jason.decode!()
      |> Map.fetch!("credential")

    assert gateway_request("/v1/compute/authenticate", %{
             "registration_id" => material["registration_id"],
             "credential_b64" => credential
           }).status == 200

    hello = %{
      "registrationId" => material["registration_id"],
      "connectionEpoch" => "1",
      "inventoryWatermark" => "1",
      "inventory" => []
    }

    assert gateway_request("/v1/compute/connections/observe", %{
             "hello_b64" => encode_json(hello)
           }).status == 200

    assert {:ok, operation} = AgentVMMInstallations.get(ctx.descriptor.operation.id)
    assert operation.status == "ready"

    binding = Repo.one!(Compute.ProviderBinding)
    assert binding.status == "available"
    assert binding.provider_ref == material["registration_id"]
    assert binding.environment_id == "environment"
  end

  defp exchange(descriptor) do
    request(
      "/v1/compute/agent-vmm/install-operations/exchange",
      exchange_body(descriptor.operation.id),
      descriptor.one_time_secret
    )
  end

  defp exchange_body(operation_id) do
    %{
      "version" => 2,
      "operation_id" => operation_id,
      "device_id" => "host-device",
      "root_public_key" => Base.encode64(@root_public_key),
      "root_key_revision" => 1
    }
  end

  defp request(path, body, secret) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "InstallOperation " <> secret)
    |> SalixWeb.Router.call(SalixWeb.Router.init([]))
  end

  defp request_attrs do
    %{
      tenant_id: "tenant",
      group_id: "group",
      surface: "bft",
      scope_key: "project",
      client_request_id: "request",
      provider: "agent-vmm",
      environment_id: "environment",
      delivery_target_type: "bft_runner",
      delivery_target_id: "runner-a"
    }
  end

  defp gateway_request(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", @control_secret)
    |> put_req_header("x-agent-vmm-gateway-instance", "gateway-a")
    |> SalixWeb.Router.call(SalixWeb.Router.init([]))
  end

  defp encode_json(value), do: value |> Jason.encode!() |> Base.encode64()

  defp keypair, do: :crypto.generate_key(:ecdh, :secp256r1)

  defp compress_public_key(<<4, x::binary-size(32), y::binary-size(32)>>) do
    prefix = if rem(:binary.decode_unsigned(y), 2) == 0, do: 2, else: 3
    <<prefix, x::binary>>
  end

  defp sign(payload, private) do
    der = :crypto.sign(:ecdsa, :sha256, payload, [private, :secp256r1])
    <<0x30, _size, 0x02, r_size, rest::binary>> = der
    <<r::binary-size(^r_size), 0x02, s_size, s::binary-size(s_size)>> = rest
    r = pad32(r)
    s_value = :binary.decode_unsigned(s)
    s_value = min(s_value, @p256_order - s_value)
    r <> pad32(:binary.encode_unsigned(s_value))
  end

  defp pad32(<<0, rest::binary>>), do: pad32(rest)
  defp pad32(value), do: :binary.copy(<<0>>, 32 - byte_size(value)) <> value

  defp put_or_delete(app, key, nil), do: Application.delete_env(app, key)

  defp put_or_delete(app, key, value), do: Application.put_env(app, key, value)
end
