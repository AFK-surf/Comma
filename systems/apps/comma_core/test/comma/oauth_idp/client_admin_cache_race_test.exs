defmodule Comma.OauthIdp.ClientAdminCacheRaceTest do
  @moduledoc """
  PR #1059 review rounds 1–2: every ordering protocol for invalidating
  Boruta's TTL-less client cache around the audited lifecycle
  transaction left a permanent-staleness window (concurrent
  repopulation before commit; process death between commit and a
  post-commit sweep, unrepairable by idempotent retry because the retry
  short-circuits on `admin_command_already_succeeded`).

  The resolution (architecture decision, review-loop rule): the client
  resolution path holds **no second source of truth** —
  `Comma.OauthIdp.Clients.get_client/1` reads the committed row on every
  call. These tests pin that unified guarantee at the same boundary the
  reviewer exercised: real committed transactions on independent
  connections (`unboxed_run`; the sandbox would serialize the
  interleaving), with **no recovery step of any kind** between commit
  and the assertion — exactly the crash-plus-retry gap: if correctness
  needed a post-commit action, these tests would fail.
  """
  use ExUnit.Case, async: false

  alias Comma.OauthIdp.ClientAdmin

  setup do
    Comma.OauthIdpTestKeys.install_kek()

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
      Comma.Repo.delete_all(Boruta.Ecto.Token)
      Comma.Repo.delete_all(Boruta.Ecto.Client)
      Comma.Repo.delete_all(Comma.OauthIdp.SigningKeys.Key)
      Comma.OauthIdp.SigningKeys.provision_initial!()
    end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
        Comma.Repo.delete_all(Boruta.Ecto.Token)
        Comma.Repo.delete_all(Boruta.Ecto.Client)
        Comma.Repo.delete_all(Comma.OauthIdp.SigningKeys.Key)
      end)
    end)

    :ok
  end

  defp resolve(client_id) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
      Comma.OauthIdp.Clients.get_client(client_id)
    end)
  end

  test "disable is effective at commit even when a resolver raced the open transaction and nothing runs afterwards" do
    client =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
        {:ok, client} =
          ClientAdmin.create(%{
            "name" => "Race Probe",
            "redirect_uris" => ["https://race.example.com/cb"]
          })

        client
      end)

    test_pid = self()

    command =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
          Comma.Repo.transaction(fn ->
            {:ok, _disabled} = ClientAdmin.disable(client["id"])
            send(test_pid, :disabled_inside_tx)

            receive do
              :commit -> :ok
            after
              10_000 -> raise "resolver never raced"
            end
          end)
        end)
      end)

    assert_receive :disabled_inside_tx, 10_000

    # The racing resolver reads the old committed row while the audited
    # transaction is open — correct at that instant, and in the cached
    # design this is the read that poisoned the cache forever.
    assert %Boruta.Oauth.Client{} = resolve(client["id"])

    send(command.pid, :commit)
    assert {:ok, _result} = Task.await(command, 10_000)

    # Nothing runs between commit and this assertion — no sweep, no
    # retry, no recovery. This is the process-death gap: resolution must
    # be correct from the committed state alone.
    assert resolve(client["id"]) == nil
  end

  test "rotation is effective at commit with no follow-up step" do
    client =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
        {:ok, client} =
          ClientAdmin.create(%{
            "name" => "Rotate Probe",
            "redirect_uris" => ["https://race.example.com/cb"],
            "confidential" => true
          })

        client
      end)

    old_secret = client["client_secret"]

    # Warm any would-be cache with the old secret.
    assert %Boruta.Oauth.Client{secret: ^old_secret} = resolve(client["id"])

    {:ok, rotated} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
        ClientAdmin.rotate_secret(client["id"])
      end)

    new_secret = rotated["client_secret"]
    assert new_secret != old_secret

    # Immediately after commit, with no invalidation step, resolution
    # serves the new secret.
    assert %Boruta.Oauth.Client{secret: ^new_secret} = resolve(client["id"])
  end
end
