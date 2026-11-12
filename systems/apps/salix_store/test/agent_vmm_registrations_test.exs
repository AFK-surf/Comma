defmodule SalixStore.AgentVMMRegistrationsTest do
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixStore"]
  require SystemsRuntime.Proc
  import Ecto.Query
  alias SalixStore.{AgentVMM, AgentVMMRegistrations, Compute, Repo}
  alias AgentVMM.Registration

  setup do
    SalixStore.RepoTestSetup.exclusively(fn ->
      Repo.query!(
        "TRUNCATE compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
      )
    end)

    {:ok, pool} = Compute.ensure_managed_default_pool("tenant", "agent_vmm")

    {:ok, _} =
      Compute.create_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    SystemsRuntime.Test.put_env(
      :salix_store,
      :agent_vmm_connection_config,
      SalixStore.AgentVMMConnectionConfigFixtures.catalog()
    )

    :ok
  end

  test "one claim accepts the persisted client credential and authenticates a lost-response retry after ticket expiry" do
    now = SystemsClock.utc_now()
    {:ok, d} = request()
    candidate = String.duplicate("e", 43)
    assert {:ok, config} = claim(d, candidate)
    assert config.registration_id == d.registration.id
    assert config.remote_connection.gateway_endpoint == "vmm.example.test:7443"
    assert :ok = AgentVMM.authenticate_registration(d.registration.id, candidate)
    r = Repo.get!(Registration, d.registration.id)
    assert is_nil(r.ticket_secret_hash)
    assert r.credential_hash == :crypto.hash(:sha256, candidate)
    assert Repo.aggregate(Compute.ProviderBinding, :count) == 1

    assert {:ok, ^config} =
             AgentVMMRegistrations.claim(r.id, "no-longer-valid", identity(), candidate,
               now: DateTime.add(now, 901, :second)
             )

    assert Repo.get!(Registration, r.id).revision == r.revision
    assert Repo.aggregate(Compute.Workload, :count) == 0

    assert {:error, :host_identity_mismatch} =
             AgentVMMRegistrations.claim(r.id, d.ticket, identity(), String.duplicate("h", 43))
  end

  test "a stop committed before first claim remains stopped" do
    {:ok, d} = request()
    assert {:ok, stopped} = AgentVMMRegistrations.configure_registration(d.registration.id, false)
    assert stopped.status == "stopped"
    assert {:ok, _} = claim(d, String.duplicate("a", 43))
    r = Repo.get!(Registration, d.registration.id)
    refute r.desired_enabled
    assert r.status == "disabled"
    assert AgentVMM.authenticate_registration(r.id, String.duplicate("a", 43)) == :ok
  end

  test "late claim replay cannot undo a stop or explicit revocation" do
    {:ok, d} = request()
    candidate = String.duplicate("e", 43)
    {:ok, _} = claim(d, candidate)
    {:ok, stopped} = AgentVMMRegistrations.configure_registration(d.registration.id, false)
    assert stopped.status == "stopped"
    assert {:ok, _} = claim(d, candidate)
    refute Repo.get!(Registration, d.registration.id).desired_enabled
    {:ok, removed} = AgentVMMRegistrations.revoke(d.registration.id)
    assert removed.status == "removed"
    assert {:error, :registration_revoked} = claim(d, candidate)
  end

  test "idempotent reads preserve an expired request; only explicit retry rotates a ticket" do
    now = SystemsClock.utc_now()
    {:ok, d} = request(now: DateTime.add(now, -901, :second))
    assert {:error, :ticket_expired} = claim(d, String.duplicate("a", 43))
    assert {:ok, %{expired: 1}} = AgentVMMRegistrations.expire_tickets()
    {:ok, repeated} = request()
    assert repeated.registration.id == d.registration.id
    assert is_nil(repeated.ticket)
    assert Repo.get!(Registration, d.registration.id)
    {:ok, renewed} = AgentVMMRegistrations.retry(d.registration.id)
    refute renewed.ticket == d.ticket
    assert {:error, :invalid_ticket} = claim(d, String.duplicate("a", 43))
    assert {:ok, _} = claim(renewed, String.duplicate("a", 43))
  end

  test "BFT occupancy belongs to stable Project even after its Group changes" do
    {:ok, d} = AgentVMMRegistrations.request(attrs())

    assert {:error, :scope_host_bound} =
             AgentVMMRegistrations.request(%{
               attrs()
               | client_request_id: "second",
                 group_id: "another-group"
             })

    {:ok, _} = AgentVMMRegistrations.revoke(d.registration.id)

    assert {:ok, _} =
             AgentVMMRegistrations.request(%{
               attrs()
               | client_request_id: "second",
                 group_id: "another-group"
             })
  end

  test "current authorization is checked again inside claim and mutation" do
    {:ok, d} = request()

    assert {:error, :authorization_changed} =
             AgentVMMRegistrations.claim(
               d.registration.id,
               d.ticket,
               identity(),
               String.duplicate("a", 43),
               authorize: fn -> {:error, :forbidden} end
             )

    assert is_nil(Repo.get!(Registration, d.registration.id).credential_hash)

    assert {:error, :authorization_changed} =
             AgentVMMRegistrations.retry(d.registration.id,
               authorize: fn -> {:error, :forbidden} end
             )
  end

  test "seven-day credential expiry preserves identity and work and requires a fresh candidate under the original root" do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private} =
      SystemsRuntime.Proc.generate_key(:ecdh, :secp256r1)

    public = <<2 + Bitwise.band(:binary.last(y), 1), x::binary>>
    host = %{identity() | root_public_key: public}
    {:ok, d} = request()
    old = String.duplicate("a", 43)

    {:ok, _} =
      AgentVMMRegistrations.claim(d.registration.id, d.ticket, host, old,
        authorize: fn -> :ok end
      )

    {:ok, _} = AgentVMMRegistrations.configure_registration(d.registration.id, false)

    Repo.update_all(from(r in Registration, where: r.id == ^d.registration.id),
      set: [authorization_expires_at: DateTime.add(SystemsClock.utc_now(), -1, :second)]
    )

    assert {:error, :unauthorized} = AgentVMM.authenticate_registration(d.registration.id, old)

    assert {:error, :authorization_expired} =
             AgentVMMRegistrations.claim(d.registration.id, d.ticket, host, old)

    replacement = String.duplicate("b", 43)

    opts = [
      authorize: fn -> :ok end,
      candidate_credential_hash: Base.encode64(:crypto.hash(:sha256, replacement))
    ]

    assert {:ok, challenge} =
             AgentVMMRegistrations.recovery_challenge(d.registration.id, authority(), opts)

    {:ok, wire} = SalixStore.AgentVMMRecovery.wire(challenge.challenge)

    <<0x30, _, 0x02, r_size, rest::binary>> =
      SystemsRuntime.Proc.sign(:ecdsa, :sha256, wire, [private, :secp256r1])

    <<r::binary-size(^r_size), 0x02, s_size, v::binary-size(s_size)>> = rest
    order = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
    r = :binary.decode_unsigned(r)
    v = :binary.decode_unsigned(v)
    signature = <<r::256, min(v, order - v)::256>>

    proof = %{
      "device_id" => host.device_id,
      "root_public_key" => Base.encode64(public),
      "root_key_revision" => 1,
      "nonce" => challenge.challenge["nonce"],
      "signature" => Base.encode64(signature)
    }

    assert {:error, :invalid_recovery_challenge} =
             AgentVMMRegistrations.replace_credential(
               d.registration.id,
               authority(),
               proof,
               Base.encode64(String.duplicate("c", 43)),
               opts
             )

    assert {:ok, recovered} =
             AgentVMMRegistrations.replace_credential(
               d.registration.id,
               authority(),
               proof,
               Base.encode64(replacement),
               opts
             )

    assert recovered.id == d.registration.id
    assert recovered.status == "stopped"
    assert :ok = AgentVMM.authenticate_registration(recovered.id, replacement)
    assert {:error, :unauthorized} = AgentVMM.authenticate_registration(recovered.id, old)
    revision = Repo.get!(Registration, recovered.id).revision

    assert {:ok, _} =
             AgentVMMRegistrations.replace_credential(
               recovered.id,
               authority(),
               proof,
               Base.encode64(replacement),
               opts
             )

    assert Repo.get!(Registration, recovered.id).revision == revision
    assert Repo.aggregate(Compute.ProviderBinding, :count) == 1
    {:ok, _} = AgentVMMRegistrations.revoke(recovered.id)

    assert {:error, :recovery_target_unavailable} =
             AgentVMMRegistrations.recovery_challenge(recovered.id, authority(), opts)
  end

  test "a bound legacy Host with no credential cannot be first-claimed with a ticket" do
    {:ok, d} = request()

    Repo.update_all(from(r in Registration, where: r.id == ^d.registration.id),
      set: [host_identity_digest: :binary.copy(<<9>>, 32), device_id: "old-device"]
    )

    assert {:error, :credential_reauthorization_required} = claim(d, String.duplicate("a", 43))
  end

  test "request cancellation serializes with an authorization already holding the owner lock" do
    parent = SystemsRuntime.Proc.self()

    attrs =
      Map.merge(attrs(), %{
        surface: "comma",
        delivery_target_type: "comma_main_device",
        authorizing_subject_id: "subject",
        authorizing_audience: "https://api.example.test"
      })

    request =
      SystemsRuntime.Task.async(fn ->
        AgentVMMRegistrations.request(attrs,
          authorize: fn ->
            SystemsRuntime.Proc.send(parent, {:request_locked, SystemsRuntime.Proc.self()})

            SystemsRuntime.Proc.receive do
              :continue_authorization -> :ok
            end
          end
        )
      end)

    settle_receive({:request_locked, authorizer})
    cancel = SystemsRuntime.Task.async(fn -> AgentVMMRegistrations.cancel_request(attrs) end)
    wait_for_owner_waiter!(100)
    SystemsRuntime.Proc.send(authorizer, :continue_authorization)
    assert {:ok, requested} = settled_await(request)
    assert {:ok, removed} = settled_await(cancel)
    assert removed.id == requested.registration.id
    assert removed.status == "removed"
    refute removed.host_bound
    assert {:error, :registration_revoked} = claim(requested, String.duplicate("a", 43))
    assert {:ok, replay} = AgentVMMRegistrations.request(attrs)
    assert replay.registration.id == removed.id
    assert is_nil(replay.ticket)
    assert Repo.aggregate(Compute.ProviderBinding, :count) == 0
  end

  defp wait_for_owner_waiter!(0), do: flunk("cancel did not reach the held owner lock")

  defp wait_for_owner_waiter!(remaining) do
    [[waiting]] =
      Repo.query!(
        "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND NOT granted AND objid::bigint=(hashtext($1)::bigint & 4294967295))",
        ["agent-vmm-registration:comma:project"]
      ).rows

    unless waiting do
      SystemsClock.sleep(1)
      wait_for_owner_waiter!(remaining - 1)
    end
  end

  defp attrs do
    %{
      tenant_id: "tenant",
      group_id: "group",
      surface: "bft",
      owner_id: "project",
      client_request_id: "request",
      environment_id: "environment",
      delivery_target_type: "bft_runner",
      delivery_target_id: "runner"
    }
  end

  defp request(opts \\ []), do: AgentVMMRegistrations.request(attrs(), opts)

  defp claim(d, candidate),
    do:
      AgentVMMRegistrations.claim(d.registration.id, d.ticket, identity(), candidate,
        authorize: fn -> :ok end
      )

  defp identity, do: %{device_id: "host", root_public_key: <<2, 0::256>>, root_key_revision: 1}

  defp authority,
    do: %{
      tenant_id: "tenant",
      group_id: "group",
      owner_id: "project",
      subject: "current-admin",
      audience: "https://api.example.test",
      session_id: "new-session"
    }
end
