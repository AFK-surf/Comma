defmodule Comma.AuthAbuseVerifierTest do
  require SystemsRuntime.Proc
  use Comma.DataCase, async: false
  use SystemsClock.Test, scope: ["Elixir.Comma"], epoch: ~U[2026-01-01 00:00:00Z]
  alias Comma.Auth.Abuse.{Apple, AppleKey, AppleVerifier}
  alias Comma.Auth.AbuseFixtures, as: Fixture

  setup do
    fixture = Fixture.apple("comma-abuse:example:secret")

    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse,
      enabled: true,
      apple: [
        app_id: Fixture.app_id(),
        environment: "production",
        verifier_options: [root: fixture.root]
      ]
    )

    %{fixture: fixture, bytes: "comma-abuse:example:secret"}
  end

  test "an unchanged published iOS assertion verifies with its original key and client data" do
    path = Path.expand("../fixtures/app_attest/ios-14.4-assertion.json", __DIR__)
    sample = path |> File.read!() |> Jason.decode!()
    [entry] = :public_key.pem_decode(sample["publicKey"])
    {{:ECPoint, point}, {:namedCurve, _}} = :public_key.pem_entry_decode(entry)
    client_data = Base.decode64!(sample["clientDataBase64"])

    assert :crypto.hash(:sha256, client_data) ==
             Base.decode64!(sample["clientDataHashSha256Base64"])

    app = sample["teamIdentifier"] <> "." <> sample["bundleIdentifier"]

    assert {:ok, 1} =
             AppleVerifier.assert_proof(sample["assertionBase64"], client_data, point, 0, app)

    assert {:error, :invalid_assertion} =
             AppleVerifier.assert_proof(
               sample["assertionBase64"],
               client_data <> "-other",
               point,
               0,
               app
             )
  end

  test "the production verifier validates a chain and bound assertion, including extension data",
       %{fixture: fixture, bytes: bytes} do
    assert {:ok, %{public_key: key, counter: 0}} = attest(fixture, bytes)
    assertion = Fixture.assertion(bytes, fixture, 1, extensions: <<0xA0>>)
    assert {:ok, 1} = AppleVerifier.assert_proof(assertion, bytes, key, 0, fixture.app_id)

    assert {:error, :invalid_assertion} =
             AppleVerifier.assert_proof(assertion, bytes, key, 1, fixture.app_id)

    assert {:error, :invalid_assertion} =
             AppleVerifier.assert_proof(assertion, bytes <> "-other", key, 0, fixture.app_id)

    assert {:error, :invalid_assertion} =
             AppleVerifier.assert_proof(assertion, bytes, key, 0, "OTHER.app")
  end

  test "a valid unrelated root, forged leaf, nonce, app, environment and malformed encoding cannot attest",
       %{fixture: fixture, bytes: bytes} do
    other = Fixture.apple(bytes, seed: 4)

    [root_entry] =
      File.read!(Application.app_dir(:comma_core, "priv/auth/apple-app-attest-root.pem"))
      |> :public_key.pem_decode()

    {:Certificate, unrelated, :not_encrypted} = root_entry

    assert {:error, :invalid_attestation} =
             AppleVerifier.attest(
               fixture.attestation,
               fixture.key_id,
               bytes,
               fixture.app_id,
               :production,
               root: unrelated
             )

    assert {:error, :invalid_attestation} = attest(fixture, bytes <> "-other")

    assert {:error, :invalid_attestation} =
             AppleVerifier.attest(
               fixture.attestation,
               fixture.key_id,
               bytes,
               "OTHER.app",
               :production,
               root: fixture.root
             )

    assert {:error, :invalid_attestation} =
             AppleVerifier.attest(
               fixture.attestation,
               fixture.key_id,
               bytes,
               fixture.app_id,
               :development,
               root: fixture.root
             )

    assert {:error, :invalid_attestation} =
             AppleVerifier.attest(
               fixture.attestation,
               other.key_id,
               bytes,
               fixture.app_id,
               :production,
               root: fixture.root
             )

    {:ok, object, ""} = fixture.attestation |> Base.decode64!() |> CBOR.decode()
    [leaf | rest] = object["attStmt"]["x5c"]
    last = byte_size(leaf.value) - 1
    <<body::binary-size(^last), bit>> = leaf.value

    forged =
      put_in(object, ["attStmt", "x5c"], [
        %{leaf | value: body <> <<Bitwise.bxor(bit, 1)>>} | rest
      ])
      |> CBOR.encode()
      |> Base.encode64()

    assert {:error, :invalid_attestation} =
             AppleVerifier.attest(forged, fixture.key_id, bytes, fixture.app_id, :production,
               root: fixture.root
             )

    assert {:error, :invalid_attestation} =
             AppleVerifier.attest("bad", fixture.key_id, bytes, fixture.app_id, :production,
               root: fixture.root
             )
  end

  test "key material stays bound to its exact target and re-enrollment does not reset its counter",
       %{fixture: fixture, bytes: bytes} do
    proof = %{"key_id" => fixture.key_id, "attestation" => fixture.attestation}
    assert :ok = Apple.verify(proof, bytes, "owner@example.com")
    assert {:error, :native_proof_rejected} = Apple.verify(proof, bytes, "other@example.com")
    assertion = Fixture.assertion(bytes, fixture, 1)

    assert :ok =
             Apple.verify(
               %{"key_id" => fixture.key_id, "assertion" => assertion},
               bytes,
               "owner@example.com"
             )

    assert :ok = Apple.verify(proof, bytes, "owner@example.com")
    assert Repo.get!(AppleKey, fixture.key_id).counter == 1

    assert {:error, :native_proof_rejected} =
             Apple.verify(
               %{"key_id" => fixture.key_id, "assertion" => assertion},
               bytes,
               "owner@example.com"
             )

    assert :ok = Apple.delete_for_email("other@example.com")
    assert Repo.get(AppleKey, fixture.key_id)
    assert :ok = Apple.delete_for_email("owner@example.com")
    assert Repo.get(AppleKey, fixture.key_id) == nil
  end

  test "fingerprint rotation leaves old rows unmatched, and restoring the secret can match them again",
       %{fixture: fixture, bytes: bytes} do
    proof = %{"key_id" => fixture.key_id, "attestation" => fixture.attestation}
    assert :ok = Apple.verify(proof, bytes, "owner@example.com")
    auth = SystemsRuntime.get_env(:comma_core, :auth)

    SystemsRuntime.Test.put_env(
      :comma_core,
      :auth,
      Keyword.put(auth, :rate_limit_secret, "rotated-fingerprint-secret")
    )

    assertion = %{"key_id" => fixture.key_id, "assertion" => Fixture.assertion(bytes, fixture, 1)}
    assert {:error, :native_proof_rejected} = Apple.verify(assertion, bytes, "owner@example.com")
    assert :ok = Apple.delete_for_email("owner@example.com")
    assert Repo.get(AppleKey, fixture.key_id)
    SystemsRuntime.Test.put_env(:comma_core, :auth, auth)
    assert :ok = Apple.verify(assertion, bytes, "owner@example.com")
  end

  test "certificate validity follows the owned manual clock, independent of host time", %{
    bytes: bytes
  } do
    now = SystemsClock.utc_now()
    validity = X509.Certificate.Validity.new(DateTime.add(now, -1), DateTime.add(now, 1))
    fixture = Fixture.apple(bytes, validity: validity)
    assert {:ok, _} = attest(fixture, bytes)
    SystemsClock.advance(2_000)
    assert {:error, :invalid_attestation} = attest(fixture, bytes)
    future = X509.Certificate.Validity.new(DateTime.add(now, 10), DateTime.add(now, 20))
    assert {:error, :invalid_attestation} = attest(Fixture.apple(bytes, validity: future), bytes)
  end

  @tag sandbox: false
  test "concurrent identical assertions advance the persisted counter only once", %{
    fixture: fixture,
    bytes: bytes
  } do
    unboxed = fn fun -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end

    assert :ok =
             unboxed.(fn ->
               Apple.verify(
                 %{"key_id" => fixture.key_id, "attestation" => fixture.attestation},
                 bytes,
                 "owner@example.com"
               )
             end)

    on_exit(fn ->
      unboxed.(fn -> Repo.delete_all(from(k in AppleKey, where: k.key_id == ^fixture.key_id)) end)
    end)

    parent = SystemsRuntime.Proc.self()
    handler = "app-attest-counter-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:comma, :repo, :query],
        &__MODULE__.pause_key_read/4,
        {parent, fixture.key_id}
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)
    assertion = Fixture.assertion(bytes, fixture, 1)

    tasks =
      for _ <- 1..2 do
        SystemsRuntime.Task.async(fn ->
          unboxed.(fn ->
            Apple.verify(
              %{"key_id" => fixture.key_id, "assertion" => assertion},
              bytes,
              "owner@example.com"
            )
          end)
        end)
      end

    settle_receive({:key_read, first})
    settle_receive({:key_read, second})
    SystemsRuntime.Proc.send(first, :accept_assertion)
    SystemsRuntime.Proc.send(second, :accept_assertion)
    results = Enum.map(tasks, &settled_await/1)
    SystemsRuntime.Telemetry.detach(handler)
    assert Enum.sort(results) == Enum.sort([:ok, {:error, :native_proof_rejected}])
    assert unboxed.(fn -> Repo.get!(AppleKey, fixture.key_id).counter end) == 1
  end

  @tag sandbox: false
  test "an assertion cannot update a key that was retired and enrolled for another target", %{
    fixture: fixture,
    bytes: bytes
  } do
    unboxed = fn fun -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end

    assert :ok =
             unboxed.(fn ->
               Apple.verify(
                 %{"key_id" => fixture.key_id, "attestation" => fixture.attestation},
                 bytes,
                 "owner@example.com"
               )
             end)

    on_exit(fn ->
      unboxed.(fn -> Repo.delete_all(from(k in AppleKey, where: k.key_id == ^fixture.key_id)) end)
    end)

    parent = SystemsRuntime.Proc.self()
    handler = "app-attest-retire-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:comma, :repo, :query],
        &__MODULE__.pause_key_read/4,
        {parent, fixture.key_id}
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)
    assertion = Fixture.assertion(bytes, fixture, 1)

    task =
      SystemsRuntime.Task.async(fn ->
        unboxed.(fn ->
          Apple.verify(
            %{"key_id" => fixture.key_id, "assertion" => assertion},
            bytes,
            "owner@example.com"
          )
        end)
      end)

    settle_receive({:key_read, reader})
    SystemsRuntime.Telemetry.detach(handler)

    unboxed.(fn ->
      assert :ok = Apple.delete_for_email("owner@example.com")

      assert :ok =
               Apple.verify(
                 %{"key_id" => fixture.key_id, "attestation" => fixture.attestation},
                 bytes,
                 "other@example.com"
               )
    end)

    SystemsRuntime.Proc.send(reader, :accept_assertion)
    assert {:error, :native_proof_rejected} = settled_await(task)
    assert unboxed.(fn -> Repo.get!(AppleKey, fixture.key_id).counter end) == 0
  end

  def pause_key_read(_event, _measurements, metadata, {parent, key_id}) do
    if String.starts_with?(metadata.query, "SELECT") and
         String.contains?(metadata.query, "comma_app_attest_keys") and key_id in metadata.params do
      SystemsRuntime.Proc.send(parent, {:key_read, SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
        :accept_assertion -> :ok
      end
    end
  end

  defp attest(fixture, bytes),
    do:
      AppleVerifier.attest(
        fixture.attestation,
        fixture.key_id,
        bytes,
        fixture.app_id,
        :production,
        root: fixture.root
      )
end
