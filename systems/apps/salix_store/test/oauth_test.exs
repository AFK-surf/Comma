defmodule SalixStore.OAuthTest do
  @moduledoc "OAuth refresh serialized by CAS, against both backends."
  use SystemsClock.Case, async: false

  alias SalixStore.OAuth

  for {backend, name} <- [{SalixStore.S3.AWS, "MinIO"}, {SalixStore.S3.Fake, "Fake"}] do
    describe "#{name}: oauth refresh" do
      setup do
        prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
        SystemsRuntime.put_env(:salix_store, :s3_backend, unquote(backend))
        if unquote(backend) == SalixStore.S3.Fake, do: start_supervised!(SalixStore.S3.Fake)
        on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
        {:ok, id: "conn-#{SystemsRuntime.Proc.unique_integer([:positive])}"}
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

      test "a caller arriving during an exchange keeps the current token while it lasts",
           %{id: id} do
        :ok = OAuth.put(id, expired_record())

        # Within the leeway (expires at 10_000), the holder exchanges; a
        # second caller sees the lease and must not spend the refresh token.
        holder = fn record ->
          assert {:ok, "old"} =
                   OAuth.valid_token(id, fn _ -> flunk("second exchange") end,
                     now: 5_000,
                     leeway_ms: 60_000
                   )

          rotation("tok-2", "r2").(record)
        end

        assert {:ok, "tok-2"} = OAuth.valid_token(id, holder, now: 5_000, leeway_ms: 60_000)

        assert {:ok,
                %{"access_token" => "tok-2", "refresh_token" => "r2", "version" => 2} = final} =
                 OAuth.get(id)

        refute Map.has_key?(final, "refresh_lease_until")
      end

      test "a caller arriving during an exchange of an expired token is told to retry",
           %{id: id} do
        :ok = OAuth.put(id, expired_record())

        holder = fn record ->
          assert {:error, :refresh_in_progress} =
                   OAuth.valid_token(id, fn _ -> flunk("second exchange") end, now: 20_000)

          rotation("tok-2", "r2").(record)
        end

        assert {:ok, "tok-2"} = OAuth.valid_token(id, holder, now: 20_000)
      end

      test "a holder refused after its lease ran out returns the next holder's token",
           %{id: id} do
        :ok = OAuth.put(id, expired_record())

        # The first holder's exchange outlives its lease; the next caller
        # takes a new lease, spends the refresh token and stores the
        # rotation, so the provider refuses the first holder.
        stale_holder = fn _record ->
          assert {:ok, "tok-2"} =
                   OAuth.valid_token(id, rotation("tok-2", "r2"), now: 20_000 + 60_001)

          {:error, :reauthorization_required}
        end

        assert {:ok, "tok-2"} = OAuth.valid_token(id, stale_holder, now: 20_000)

        assert {:ok,
                %{"access_token" => "tok-2", "refresh_token" => "r2", "version" => 2} = final} =
                 OAuth.get(id)

        refute final["status"] == "reauthorization_required"
      end

      test "a mark landing between a refresher's exchange and its write keeps the new tokens",
           %{id: id} do
        :ok = OAuth.put(id, expired_record())

        holder = fn record ->
          assert :ok = OAuth.mark_reauthorization_required(id, record)
          rotation("tok-2", "r2").(record)
        end

        assert {:ok, "tok-2"} = OAuth.valid_token(id, holder, now: 20_000)

        assert {:ok,
                %{"access_token" => "tok-2", "refresh_token" => "r2", "status" => "active"} =
                  final} = OAuth.get(id)

        refute Map.has_key?(final, "refresh_lease_until")
      end

      test "a refused refresh with no rotation returns the error and releases the lease",
           %{id: id} do
        :ok = OAuth.put(id, expired_record())

        assert {:error, :reauthorization_required} =
                 OAuth.valid_token(id, fn _ -> {:error, :reauthorization_required} end,
                   now: 20_000
                 )

        assert {:ok, %{"access_token" => "old", "version" => 1} = record} = OAuth.get(id)
        refute Map.has_key?(record, "refresh_lease_until")
      end

      test "mark_reauthorization_required skips a record whose refresh token rotated",
           %{id: id} do
        :ok = OAuth.put(id, Map.put(expired_record(), "refresh_token", "r2"))

        assert :ok = OAuth.mark_reauthorization_required(id, %{"refresh_token" => "r"})
        assert {:ok, record} = OAuth.get(id)
        refute record["status"] == "reauthorization_required"

        assert :ok = OAuth.mark_reauthorization_required(id, %{"refresh_token" => "r2"})
        assert {:ok, %{"status" => "reauthorization_required"}} = OAuth.get(id)
      end

      test "mark_reauthorization_required without a seen record always marks", %{id: id} do
        :ok = OAuth.put(id, expired_record())

        assert :ok = OAuth.mark_reauthorization_required(id)
        assert {:ok, %{"status" => "reauthorization_required"}} = OAuth.get(id)
        assert :ok = OAuth.mark_reauthorization_required("missing-#{id}")
      end
    end
  end

  defp expired_record do
    %{"access_token" => "old", "expires_at" => 10_000, "refresh_token" => "r", "version" => 1}
  end

  defp rotation(access_token, refresh_token) do
    fn _record ->
      {:ok,
       %{
         "access_token" => access_token,
         "refresh_token" => refresh_token,
         "expires_at" => 100_000
       }}
    end
  end
end
