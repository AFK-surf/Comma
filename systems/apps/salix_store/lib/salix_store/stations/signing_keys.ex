defmodule SalixStore.Stations.SigningKeys do
  @moduledoc """
  Ed25519 keys that sign member credentials for stations, with the custody
  and rotation of `Comma.Stations.SigningKeys`: the private half is
  AES-256-GCM ciphertext under the deployment KEK; exactly one row is
  `signing`, a `pending` row is published to stations (presence `grant_keys`)
  before it signs, and `verify_only` rows keep issued credentials verifiable
  until `retire_after`. Partial unique indexes make "one signing, one pending"
  a database guarantee.

  The keys Comma's stations pinned are copied here with their kid and key
  material (Comma migration 20261010200002), so the KEK and the AEAD label are
  the ones Comma sealed them under: `config :salix_store, :stations, kek:`
  (COMMA_STATION_SIGNING_KEK), else HKDF-SHA256 of the subscription storage
  key under Comma's station label. Without either, keys are unavailable and
  callers fail closed.

  Telling connected stations that the key set changed belongs to the caller.
  """

  import Ecto.Query

  alias SalixStore.Repo

  defmodule Key do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:kid, :string, autogenerate: false}
    schema "salix_station_signing_keys" do
      field(:public_key, :binary)
      field(:private_key_ciphertext, :binary)
      field(:private_key_iv, :binary)
      field(:private_key_tag, :binary)
      field(:status, :string)
      field(:retire_after, :utc_datetime_usec)

      timestamps(
        type: :utc_datetime_usec,
        inserted_at: :created_at,
        autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
      )
    end
  end

  # The label and AAD the copied Comma keys were sealed under.
  @kek_label "comma.stations.signing.kek.v1"
  @aad "comma_station_signing_keys.private_key"
  @default_prepublish_seconds 3600
  # A credential lasts 30 days; a retired key verifies one day longer.
  @verify_window_seconds 31 * 24 * 60 * 60

  @doc "The deployment KEK, or `{:error, :stations_unavailable}`."
  def kek do
    case SystemsRuntime.get_env(:salix_store, :stations, [])[:kek] do
      <<_::binary-size(32)>> = kek ->
        {:ok, kek}

      _ ->
        case SystemsRuntime.get_env(:salix_agent, :subscription_storage_key) do
          <<_::binary-size(32)>> = root -> {:ok, hkdf(root, @kek_label)}
          _ -> {:error, :stations_unavailable}
        end
    end
  end

  @doc "The active signer as `{seed, kid}`; provisions the first key when none exists."
  def signer do
    with {:ok, kek} <- kek() do
      case Repo.one(from(k in Key, where: k.status == "signing")) do
        nil -> provision_initial(kek)
        %Key{} = key -> decrypt(key, kek)
      end
    end
  end

  @doc "The public halves stations verify with (`grant_keys`), the signer first."
  def grant_keys do
    now = SystemsClock.utc_now()

    keys =
      Repo.all(
        from(k in Key,
          where: is_nil(k.retire_after) or k.retire_after > ^now,
          order_by: [desc: k.status == "signing", asc: k.created_at, asc: k.kid]
        )
      )

    %{"keys" => Enum.map(keys, &public_jwk/1)}
  end

  def public_jwk(%Key{} = key) do
    %{
      "kty" => "OKP",
      "crv" => "Ed25519",
      "x" => Base.url_encode64(key.public_key, padding: false),
      "kid" => key.kid,
      "alg" => "EdDSA",
      "use" => "sig"
    }
  end

  @doc "Step 1 of routine rotation: publish a new key as `pending`."
  def prepublish!(opts \\ []) do
    {:ok, kek} = kek()
    insert!(kek, "pending", Keyword.get(opts, :kid, generate_kid()))
  end

  @doc """
  Step 2: promote the pending key once it has been published for
  `prepublish_seconds`; the previous signer verifies for 31 more days.
  """
  def activate!(opts \\ []) do
    required = Keyword.get(opts, :prepublish_seconds, @default_prepublish_seconds)

    Repo.transaction(fn ->
      pending =
        Repo.one(from(k in Key, where: k.status == "pending", lock: "FOR UPDATE")) ||
          Repo.rollback(:no_pending)

      if DateTime.diff(SystemsClock.utc_now(), pending.created_at, :second) < required,
        do: Repo.rollback(:too_early)

      retire_after = DateTime.add(SystemsClock.utc_now(), @verify_window_seconds, :second)

      Repo.update_all(from(k in Key, where: k.status == "signing"),
        set: [status: "verify_only", retire_after: retire_after]
      )

      {1, _} =
        Repo.update_all(from(k in Key, where: k.kid == ^pending.kid and k.status == "pending"),
          set: [status: "signing", retire_after: nil]
        )

      pending.kid
    end)
    |> case do
      {:ok, kid} -> kid
      {:error, reason} -> raise "station signing key activation refused: #{reason}"
    end
  end

  @doc """
  Emergency rotation: a new signer at once and the compromised one deleted, so
  its forgeries stop verifying at stations as soon as they get the new state.
  """
  def rotate_compromised!(opts \\ []) do
    {:ok, kek} = kek()

    {:ok, kid} =
      Repo.transaction(fn ->
        Repo.delete_all(from(k in Key, where: k.status == "signing"))
        insert!(kek, "signing", Keyword.get(opts, :kid, generate_kid()))
      end)

    kid
  end

  @doc "Removes a pending key, or a retired key past its verification window."
  def remove!(kid) when is_binary(kid) do
    now = SystemsClock.utc_now()

    {count, _} =
      Repo.delete_all(
        from(k in Key,
          where:
            k.kid == ^kid and
              (k.status == "pending" or (k.status == "verify_only" and k.retire_after <= ^now))
        )
      )

    if count == 0, do: raise("station signing key #{inspect(kid)} is not removable")
    :ok
  end

  def list do
    Repo.all(from(k in Key, order_by: [asc: k.created_at, asc: k.kid]))
    |> Enum.map(&Map.take(&1, [:kid, :status, :retire_after, :created_at]))
  end

  defp provision_initial(kek) do
    insert!(kek, "signing", generate_kid())
    signer()
  rescue
    error in Ecto.ConstraintError ->
      # Another node provisioned it concurrently: use theirs.
      if error.constraint == "salix_station_signing_keys_one_signing",
        do: signer(),
        else: reraise(error, __STACKTRACE__)
  end

  defp insert!(kek, status, kid) do
    {public, seed} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
    iv = SystemsRuntime.Proc.random_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, seed, @aad, true)

    Repo.insert!(%Key{
      kid: kid,
      public_key: public,
      private_key_ciphertext: ciphertext,
      private_key_iv: iv,
      private_key_tag: tag,
      status: status
    })

    kid
  end

  defp decrypt(%Key{} = key, kek) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           kek,
           key.private_key_iv,
           key.private_key_ciphertext,
           @aad,
           key.private_key_tag,
           false
         ) do
      seed when is_binary(seed) -> {:ok, {seed, key.kid}}
      :error -> {:error, :stations_unavailable}
    end
  end

  # HKDF-SHA256 (RFC 5869) with an empty salt, one 32-byte output block.
  defp hkdf(ikm, info) do
    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end

  defp generate_kid,
    do: "salix-station-" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(9), padding: false)
end
