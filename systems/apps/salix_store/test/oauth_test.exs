defmodule SalixStore.OAuthTest do
  @moduledoc "OAuth refresh serialized by CAS, against both backends."
  use ExUnit.Case, async: false

  alias SalixStore.OAuth

  for {backend, name} <- [{SalixStore.S3.AWS, "MinIO"}, {SalixStore.S3.Fake, "Fake"}] do
    describe "#{name}: oauth refresh" do
      setup do
        prev = Application.get_env(:salix_store, :s3_backend)
        Application.put_env(:salix_store, :s3_backend, unquote(backend))
        if unquote(backend) == SalixStore.S3.Fake, do: start_supervised!(SalixStore.S3.Fake)
        on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
        {:ok, id: "conn-#{System.unique_integer([:positive])}"}
      end

      test "returns the token when fresh; refreshes via CAS when expired", %{id: id} do
        :ok =
          OAuth.put(id, %{
            "access_token" => "old",
            "expires_at" => 10_000,
            "refresh_token" => "r",
            "version" => 1
          })

        # fresh
        assert {:ok, "old"} =
                 OAuth.valid_token(id, fn _ -> flunk("should not refresh") end, now: 5_000)

        # expired → refresh runs once
        refresher = fn _r -> {:ok, %{"access_token" => "new", "expires_at" => 100_000}} end
        assert {:ok, "new"} = OAuth.valid_token(id, refresher, now: 20_000)
        assert {:ok, %{"version" => 2, "access_token" => "new"}} = OAuth.get(id)
      end

      test "concurrent refreshers: exactly one effective refresh", %{id: id} do
        :ok =
          OAuth.put(id, %{
            "access_token" => "old",
            "expires_at" => 10_000,
            "refresh_token" => "r",
            "version" => 1
          })

        # Each refresher returns a distinct token; only one CAS write should win.
        tasks =
          for i <- 1..5 do
            Task.async(fn ->
              OAuth.valid_token(
                id,
                fn _ -> {:ok, %{"access_token" => "tok-#{i}", "expires_at" => 100_000}} end,
                now: 20_000
              )
            end)
          end

        results = Task.await_many(tasks)
        assert Enum.all?(results, &match?({:ok, _}, &1))

        # The stored record advanced exactly one version (one effective refresh).
        {:ok, final} = OAuth.get(id)
        assert final["version"] == 2
        # all callers return the same (winning) token
        tokens = Enum.map(results, fn {:ok, t} -> t end) |> Enum.uniq()
        assert tokens == [final["access_token"]]
      end
    end
  end
end
