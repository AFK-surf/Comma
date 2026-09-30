defmodule SalixStore.OAuth.AuthStateTest do
  @moduledoc """
  OAuth authorization-state lifecycle (willow `internal/control/oauth.go`
  auth-state semantics): create-once, CAS consume (exactly one winner),
  lazy expiry on get, terminal completion/failure records, and the GC sweep.
  Against both backends.
  """
  use ExUnit.Case, async: false

  alias SalixStore.OAuth.AuthState

  @hour_ms 60 * 60 * 1000

  for {backend, name} <- [{SalixStore.S3.AWS, "MinIO"}, {SalixStore.S3.Fake, "Fake"}] do
    describe "#{name}: oauth auth states" do
      setup do
        prev = Application.get_env(:salix_store, :s3_backend)
        Application.put_env(:salix_store, :s3_backend, unquote(backend))
        if unquote(backend) == SalixStore.S3.Fake, do: start_supervised!(SalixStore.S3.Fake)
        on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
        {:ok, state: unique_state(unquote(name))}
      end

      test "create is create-once and defaults status/origin/expiry", %{state: state} do
        assert :ok = AuthState.create(base_record(state))
        assert {:error, :already_exists} = AuthState.create(base_record(state))

        {:ok, rec} = AuthState.get(state)
        assert rec["status"] == "pending"
        assert rec["origin"] == "web"
        assert rec["expires_at"] == rec["created_at"] + 600_000
        assert rec["provider"] == "github"
        assert rec["alias"] == "work"
      end

      test "create validates required fields", %{state: state} do
        assert {:error, {:invalid, _}} = AuthState.create(%{"state" => "  "})

        assert {:error, {:invalid, _}} =
                 AuthState.create(base_record(state) |> Map.delete("alias"))
      end

      test "consume claims a pending record exactly once", %{state: state} do
        :ok = AuthState.create(base_record(state))

        assert {:ok, consumed} = AuthState.consume(state)
        assert consumed["status"] == "consumed"

        # Replay loses.
        assert {:error, :already_consumed} = AuthState.consume(state)
        # Missing state.
        assert {:error, :not_found} = AuthState.consume(state <> "-missing")
      end

      test "concurrent consumers: exactly one winner", %{state: state} do
        :ok = AuthState.create(base_record(state))

        results =
          1..5
          |> Enum.map(fn _ -> Task.async(fn -> AuthState.consume(state) end) end)
          |> Task.await_many()

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &match?({:error, :already_consumed}, &1)) == 4
      end

      test "consume of an expired pending record flips and reports expired", %{state: state} do
        now = System.system_time(:millisecond)

        :ok =
          base_record(state)
          |> Map.put("created_at", now - 700_000)
          |> Map.put("expires_at", now - 100_000)
          |> AuthState.create()

        assert {:error, :expired} = AuthState.consume(state)
        # The flip persisted: the record is terminal now.
        {:ok, rec} = AuthState.get(state)
        assert rec["status"] == "expired"
        assert {:error, :expired} = AuthState.consume(state)
      end

      test "get lazily expires and persists a stale pending record", %{state: state} do
        now = System.system_time(:millisecond)

        :ok =
          base_record(state)
          |> Map.put("expires_at", now - 1)
          |> AuthState.create()

        assert {:ok, %{"status" => "expired"}} = AuthState.get(state)

        # Persisted, not just projected: a raw read shows the flip.
        {:ok, %{body: body}} = SalixStore.S3.get(AuthState.key(state))
        assert Jason.decode!(body)["status"] == "expired"

        assert {:error, :not_found} = AuthState.get(state <> "-missing")
      end

      test "record_completion stores the binding outcome", %{state: state} do
        :ok = AuthState.create(base_record(state))
        {:ok, _} = AuthState.consume(state)

        assert :ok =
                 AuthState.record_completion(state, %{
                   "binding_id" => "oauth-b1",
                   "connection_id" => "conn-c1",
                   "provider_account_name" => "octocat"
                 })

        {:ok, rec} = AuthState.get(state)
        assert rec["status"] == "completed"
        assert rec["binding_id"] == "oauth-b1"
        assert rec["connection_id"] == "conn-c1"
        assert rec["provider_account_name"] == "octocat"
        assert rec["error"] == nil
      end

      test "record_failure stores a bounded error", %{state: state} do
        :ok = AuthState.create(base_record(state))
        {:ok, _} = AuthState.consume(state)

        long_reason = String.duplicate("x", 600)
        assert :ok = AuthState.record_failure(state, long_reason)

        {:ok, rec} = AuthState.get(state)
        assert rec["status"] == "failed"
        assert String.length(rec["error"]) == 512
        assert rec["binding_id"] == nil
      end

      test "purge_expired sweeps stale pending and old terminal records", %{state: state} do
        now = System.system_time(:millisecond)
        # The sweep prefilters on LIST metadata: objects written less than one
        # TTL ago are deferred without a read. These fixtures are written by
        # the test itself, so purge from a vantage one TTL later — the
        # record-level predicates then decide, exactly as in production once
        # the objects have aged.
        purge_now = now + 11 * 60 * 1000
        stale_pending = state <> "-stale"
        old_completed = state <> "-old-completed"
        fresh_pending = state <> "-fresh"
        fresh_completed = state <> "-fresh-completed"

        :ok =
          base_record(stale_pending)
          |> Map.put("expires_at", now - 1000)
          |> AuthState.create()

        :ok =
          base_record(old_completed)
          |> Map.merge(%{"status" => "completed", "expires_at" => now - 25 * @hour_ms})
          |> AuthState.create()

        # Far-future expiry so the future purge vantage still sees it live.
        :ok =
          base_record(fresh_pending)
          |> Map.put("expires_at", now + 2 * @hour_ms)
          |> AuthState.create()

        # Recently-terminal records survive (the completion tool still polls).
        :ok =
          base_record(fresh_completed)
          |> Map.merge(%{"status" => "completed", "expires_at" => now - 1000})
          |> AuthState.create()

        {:ok, count} = AuthState.purge_expired(purge_now)
        assert count >= 2

        assert {:error, :not_found} = AuthState.get(stale_pending)
        assert {:error, :not_found} = AuthState.get(old_completed)
        assert {:ok, %{"status" => "pending"}} = AuthState.get(fresh_pending)
        assert {:ok, %{"status" => "completed"}} = AuthState.get(fresh_completed)
      end
    end
  end

  describe "Fake: purge LIST-metadata prefilter" do
    setup do
      prev = Application.get_env(:salix_store, :s3_backend)
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      start_supervised!(SalixStore.S3.Fake)
      on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
      {:ok, state: unique_state("Prefilter")}
    end

    test "a freshly written object is deferred without a record read", %{state: state} do
      now = System.system_time(:millisecond)

      # The record-level predicate already says purge (expires_at in the
      # past), but the object was just written: this pass must skip it on
      # LIST metadata alone — zero GETs, zero deletions.
      :ok = base_record(state) |> Map.put("expires_at", now - 1000) |> AuthState.create()

      SalixStore.S3.Fake.reset_read_log()
      assert {:ok, 0} = AuthState.purge_expired(now)

      reads = SalixStore.S3.Fake.read_log()
      assert Enum.any?(reads, &match?({:list, _, _}, &1))
      refute Enum.any?(reads, &match?({:get, _}, &1))

      # One TTL later the deferral ends and the deferred deletion happens.
      assert {:ok, 1} = AuthState.purge_expired(now + 11 * 60 * 1000)
      assert {:error, :not_found} = AuthState.get(state)
    end
  end

  defp base_record(state) do
    %{
      "state" => state,
      "tenant" => "default",
      "group_id" => "group-1",
      "agent_id" => nil,
      "session_id" => nil,
      "provider" => "github",
      "alias" => "work",
      "scopes" => ["repo"],
      "code_verifier" => "verifier",
      "redirect_uri" => "http://127.0.0.1:4000/v1/oauth/github/callback",
      "redirect_after" => nil,
      "origin" => "web",
      "error" => nil,
      "binding_id" => nil,
      "connection_id" => nil,
      "provider_account_name" => nil
    }
  end

  defp unique_state(name) do
    "authstate-#{String.downcase(name)}-" <>
      Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
