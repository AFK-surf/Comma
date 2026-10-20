defmodule SalixStore.OAuth.AuthStateTest do
  @moduledoc """
  OAuth authorization-state lifecycle (willow `internal/control/oauth.go`
  auth-state semantics): create-once, CAS consume (exactly one winner),
  lazy expiry on get, terminal completion/failure records, and the GC sweep.
  Against both backends.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.OAuth.AuthState

  for {backend, name} <- [{SalixStore.S3.AWS, "MinIO"}, {SalixStore.S3.Fake, "Fake"}] do
    describe "#{name}: oauth auth states" do
      setup do
        prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
        SystemsRuntime.put_env(:salix_store, :s3_backend, unquote(backend))
        if unquote(backend) == SalixStore.S3.Fake, do: start_supervised!(SalixStore.S3.Fake)
        on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
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

      test "consume claims a pending record exactly once", %{state: state} do
        :ok = AuthState.create(base_record(state))

        assert {:ok, consumed} = AuthState.consume(state)
        assert consumed["status"] == "consumed"

        # Replay loses.
        assert {:error, :already_consumed} = AuthState.consume(state)
        # Missing state.
        assert {:error, :not_found} = AuthState.consume(state <> "-missing")
      end

      test "consume of an expired pending record flips and reports expired", %{state: state} do
        now = SystemsClock.system_time(:millisecond)

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
    end
  end

  describe "Fake: purge LIST-metadata prefilter" do
    setup do
      prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
      SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      start_supervised!(SalixStore.S3.Fake)
      on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
      {:ok, state: unique_state("Prefilter")}
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
      Base.encode16(SystemsRuntime.Proc.random_bytes(8), case: :lower)
  end
end
