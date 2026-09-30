defmodule Comma.OauthIdp.KeyRotationConcurrencyTest do
  @moduledoc """
  The two admin-command races from the sixth #1019 review, as permanent
  regressions. These run OUTSIDE the SQL sandbox (`unboxed_run`) because
  the races are between real committed transactions on separate
  connections — exactly what the sandbox serializes away.

  Race 1: two concurrent pre-publish commands. The one-pending partial
  unique index is the arbiter: exactly one succeeds.

  Race 2: activation racing removal of the same pending key. Both
  commands lock the row for their whole transition, so every
  interleaving ends with exactly one signing key — the zero-signer
  commit the review drove is unrepresentable.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Comma.OauthIdp.SigningKeys
  alias Comma.OauthIdp.SigningKeys.Key
  alias Comma.OauthIdpTestKeys

  setup do
    previous = Application.get_env(:comma_core, :oauth_idp)
    OauthIdpTestKeys.install_kek()

    Application.put_env(
      :comma_core,
      :oauth_idp,
      Keyword.put(Application.get_env(:comma_core, :oauth_idp), :rotation_prepublish_seconds, 0)
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:comma_core, :oauth_idp)
        config -> Application.put_env(:comma_core, :oauth_idp, config)
      end

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
        Comma.Repo.delete_all(Key)
      end)
    end)

    :ok
  end

  defp signing_count do
    Comma.Repo.aggregate(from(k in Key, where: k.status == "signing"), :count)
  end

  defp concurrently(funs) do
    funs
    |> Enum.map(fn fun ->
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
          try do
            {:ok, fun.()}
          rescue
            error -> {:error, error}
          end
        end)
      end)
    end)
    |> Task.await_many(30_000)
  end

  test "two concurrent pre-publish commands: exactly one wins" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
      Comma.Repo.delete_all(Key)
      SigningKeys.provision_initial!()
    end)

    results =
      concurrently([fn -> SigningKeys.prepublish!() end, fn -> SigningKeys.prepublish!() end])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %RuntimeError{}}, &1)) == 1

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
      assert Comma.Repo.aggregate(from(k in Key, where: k.status == "pending"), :count) == 1
    end)
  end

  test "activation racing removal of the pending key never commits zero signers" do
    for _round <- 1..8 do
      pending_kid =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
          Comma.Repo.delete_all(Key)
          SigningKeys.provision_initial!()
          kid = SigningKeys.prepublish!()

          Comma.Repo.update_all(from(k in Key, where: k.kid == ^kid),
            set: [created_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
          )

          kid
        end)

      results =
        concurrently([
          fn -> SigningKeys.activate!() end,
          fn -> SigningKeys.remove!(pending_kid) end
        ])

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Comma.Repo, fn ->
        # THE invariant: whatever the interleaving, exactly one signer.
        assert signing_count() == 1, "interleaving committed #{signing_count()} signers"
      end)

      # And the commands agree on a single winner: activation promoted the
      # key (removal then vetoes or missed it), or removal deleted it
      # first (activation then found no pending key).
      assert Enum.count(results, &match?({:ok, _}, &1)) >= 1
    end
  end
end
