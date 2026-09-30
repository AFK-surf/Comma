defmodule Comma.OauthIdp.SigningKeys do
  @moduledoc """
  The shared signing-key set for the Comma OAuth IdP
  (docs/identity-security.md, decision D3 as revised 2026-08-25).

  Key pairs live in one `comma_oauth_signing_keys` table that every pod
  reads (Keycloak realm keys / Ory Hydra JWK store shape): exactly one
  row is `signing`; a `pending` row is published for verification but
  not yet signing; `verify_only` rows keep previously issued tokens
  verifiable until they expire. The partial unique index
  `comma_oauth_signing_keys_one_signing` makes "at most one signing key" a
  database guarantee even under concurrent commands.

  Routine rotation is a TWO-step protocol, and the wait between the
  steps is enforced by data, not by operator discipline:

    1. `prepublish!/0` inserts the new pair as `pending` — its public
       half joins the JWKS immediately, nothing signs with it yet.
    2. `activate!/0` promotes it to `signing` — but refuses to run until
       the pending key has been published for at least the contractual
       relying-party JWKS cache bound (`rotation_prepublish_seconds`).
       Any RP honoring the integration contract has therefore refreshed
       its cache — and picked up the new key — before the first token
       signed with it exists.

  Skipping the wait is only possible through the explicitly named
  emergency path (`rotate_compromised!/0`), which trades an RP-cache
  window of failing verifications for immediate revocation of a leaked
  key. Same for early removal: `remove!/1` refuses while a retired key
  is inside its verification window; `remove_compromised!/1` is the
  named bypass.

  Custody: the private half is stored as AES-256-GCM ciphertext under
  the deployment key-encryption key (KEK, `COMMA_OAUTH_IDP_KEK`), the
  same at-rest model Ory Hydra uses with its system secret. A database
  read alone yields no usable signer; the KEK is deployment
  configuration but participates in no rotation protocol — it only
  unwraps rows. Both halves of a pair live in one row, so a mismatched
  pair is unrepresentable rather than detected.
  """

  import Ecto.Query

  alias Comma.Repo

  defmodule Key do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:kid, :string, autogenerate: false}
    schema "comma_oauth_signing_keys" do
      field(:public_pem, :string)
      field(:private_pem_ciphertext, :binary)
      field(:private_pem_iv, :binary)
      field(:private_pem_tag, :binary)
      field(:status, :string)
      field(:retire_after, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end
  end

  @aad "comma_oauth_signing_keys.private_pem"

  # Contractual RP JWKS cache bound (10 min) + refresh cooldown margin.
  @default_prepublish_seconds 630

  @doc """
  Returns the active signer as `{private_pem, kid}`. Raises when no
  signing key is provisioned or the KEK is missing/wrong — a
  misconfigured deployment must fail closed, not degrade into
  `invalid_client` responses downstream.
  """
  @spec signing_key!() :: {pem :: String.t(), kid :: String.t()}
  def signing_key! do
    case Repo.one(from(k in Key, where: k.status == "signing")) do
      nil ->
        raise """
        Comma OAuth IdP has no signing key. Provision one with
        Comma.OauthIdp.SigningKeys.provision_initial!/0 (see
        docs/identity-security.md).
        """

      %Key{} = key ->
        {decrypt_private_pem!(key), key.kid}
    end
  end

  @doc """
  Returns every key's public half as JWKS entries, the signing key
  first. All pods read the same table, so every pod publishes an
  identical set at every instant — the property the retired
  multi-phase deployment protocol existed to approximate.
  """
  @spec public_jwks!() :: [%JOSE.JWK{}]
  def public_jwks! do
    keys =
      Repo.all(
        from(k in Key,
          order_by: [desc: k.status == "signing", asc: k.created_at]
        )
      )

    if keys == [] do
      raise "Comma OAuth IdP has no signing key; the JWKS would be empty"
    end

    Enum.map(keys, fn %Key{} = key ->
      public = key.public_pem |> JOSE.JWK.from_pem() |> JOSE.JWK.to_public()
      %{public | fields: Map.put(public.fields, "kid", key.kid)}
    end)
  end

  @doc """
  Step 1 of routine rotation: generates a fresh RSA-2048 pair and
  inserts it as `pending` — published in the JWKS for verification,
  not yet signing. Returns the new kid.

  Refuses when a pending key already exists (one rotation in flight at
  a time). Cancel an unwanted pending key with `remove!/1` — it has
  never signed anything, so removing it is always safe.
  """
  @spec prepublish!(keyword()) :: String.t()
  def prepublish!(opts \\ []) do
    kid = Keyword.get(opts, :kid, generate_kid())

    jwk = JOSE.JWK.generate_key({:rsa, 2048, 65_537})
    {_type, private_pem} = JOSE.JWK.to_pem(jwk)
    {_type, public_pem} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    {ciphertext, iv, tag} = encrypt_private_pem!(private_pem)

    # No check-then-act: the one-pending partial unique index is the
    # arbiter, so of two concurrent pre-publish commands exactly one
    # succeeds — the same database-level guarantee the signing status
    # already has.
    Repo.insert!(%Key{
      kid: kid,
      public_pem: public_pem,
      private_pem_ciphertext: ciphertext,
      private_pem_iv: iv,
      private_pem_tag: tag,
      status: "pending"
    })

    kid
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint == "comma_oauth_signing_keys_one_pending" do
        raise """
        Comma OAuth IdP already has a pending key. Activate it
        (activate!/0) or cancel it (remove!/1) before pre-publishing
        another.
        """
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Step 2 of routine rotation: promotes the pending key to `signing` and
  demotes the current signer to `verify_only` (stamping `retire_after`
  one verification window out) — one transaction, instantly visible to
  every pod. Returns the promoted kid.

  Refuses until the pending key has been published for at least
  `rotation_prepublish_seconds` (default #{@default_prepublish_seconds}s
  = the contractual RP JWKS cache bound plus refresh cooldown). This is
  the enforcement of the wait, not a convention: an RP honoring the
  integration contract has necessarily refreshed its cache — and picked
  up the pending key — before the first token signed with it can exist.
  """
  @spec activate!(keyword()) :: String.t()
  def activate!(opts \\ []) do
    verify_window = Keyword.get(opts, :verify_window_seconds, 3600)

    {:ok, kid} =
      Repo.transaction(fn ->
        # Lock the pending row for the whole transition so a concurrent
        # remove!/1 cannot delete it between our read and our promote —
        # the interleaving the sixth review drove to a zero-signer table.
        pending =
          Repo.one(from(k in Key, where: k.status == "pending", lock: "FOR UPDATE")) ||
            Repo.rollback(:no_pending)

        published_for = DateTime.diff(DateTime.utc_now(), pending.created_at, :second)
        required = prepublish_seconds()

        if published_for < required do
          Repo.rollback({:too_early, pending.kid, published_for, required})
        end

        retire_after = DateTime.add(DateTime.utc_now(), verify_window, :second)

        Repo.update_all(from(k in Key, where: k.status == "signing"),
          set: [status: "verify_only", retire_after: retire_after]
        )

        # Affected-row check: the locked pending row must still be the
        # one we promote. Anything else aborts the whole transition
        # rather than committing a set with no signer.
        case Repo.update_all(
               from(k in Key, where: k.kid == ^pending.kid and k.status == "pending"),
               set: [status: "signing", retire_after: nil]
             ) do
          {1, _} -> pending.kid
          {other, _} -> Repo.rollback({:promotion_lost, pending.kid, other})
        end
      end)
      |> case do
        {:ok, kid} ->
          {:ok, kid}

        {:error, :no_pending} ->
          raise "Comma OAuth IdP has no pending key; run prepublish!/0 first"

        {:error, {:too_early, kid, published_for, required}} ->
          raise """
          Comma OAuth IdP pending key #{inspect(kid)} has been
          published for #{published_for}s; the contractual RP cache bound
          requires #{required}s before it may sign. Wait, or — only for a
          compromised active key — use rotate_compromised!/0 and accept the
          RP-cache verification gap it documents.
          """

        {:error, {:promotion_lost, kid, count}} ->
          raise """
          Comma OAuth IdP pending key #{inspect(kid)} disappeared during
          activation (#{count} rows promoted); the transition was rolled
          back and the previous signer is untouched.
          """
      end

    kid
  end

  @doc """
  Provisions the FIRST signing key for a deployment that has none.
  Refuses when any key exists — after that, rotation goes through the
  two-step protocol.
  """
  @spec provision_initial!(keyword()) :: String.t()
  def provision_initial!(opts \\ []) do
    if Repo.exists?(from(k in Key)) do
      raise "Comma OAuth IdP already has keys; use prepublish!/0 + activate!/0 to rotate"
    end

    kid = prepublish!(opts)
    Repo.update_all(from(k in Key, where: k.kid == ^kid), set: [status: "signing"])
    kid
  end

  @doc """
  EMERGENCY rotation for a compromised active key: generates a fresh
  pair, makes it the signer immediately, and DELETES the compromised
  key's row — its public half must not stay in the JWKS, or forgeries
  signed with the leaked private key keep verifying. One transaction.

  The documented trade (docs/identity-security.md):
  until relying parties refresh their JWKS caches, tokens signed with
  the new key fail verification at RPs holding the old cache, and both
  forged and legitimate old-key tokens keep verifying at those same
  RPs. Immediate revocation is the priority; the routine path
  (prepublish!/activate!) is the one without a verification gap.
  """
  @spec rotate_compromised!(keyword()) :: String.t()
  def rotate_compromised!(opts \\ []) do
    kid = Keyword.get(opts, :kid, generate_kid())

    jwk = JOSE.JWK.generate_key({:rsa, 2048, 65_537})
    {_type, private_pem} = JOSE.JWK.to_pem(jwk)
    {_type, public_pem} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    {ciphertext, iv, tag} = encrypt_private_pem!(private_pem)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from(k in Key, where: k.status == "signing"))

        Repo.insert!(%Key{
          kid: kid,
          public_pem: public_pem,
          private_pem_ciphertext: ciphertext,
          private_pem_iv: iv,
          private_pem_tag: tag,
          status: "signing"
        })
      end)

    kid
  end

  @doc """
  Routine removal of a retired or pending key. Refuses:

    * the active signer (rotate first);
    * a `verify_only` key still inside its verification window
      (`now < retire_after`) — removing it would invalidate still-live
      tokens; that is what the review's early-removal regression pins.
      For a compromised key use `remove_compromised!/1`.

  A `pending` key may always be removed: it has never signed anything.
  """
  @spec remove!(String.t()) :: :ok
  def remove!(kid) when is_binary(kid) do
    delete_locked!(kid, fn
      %Key{status: "signing"} ->
        """
        Comma OAuth IdP key #{inspect(kid)} is the active signer. Rotate
        first, then remove the retired key.
        """

      %Key{status: "verify_only", retire_after: retire_after} ->
        if retire_after != nil and DateTime.compare(DateTime.utc_now(), retire_after) == :lt do
          """
          Comma OAuth IdP key #{inspect(kid)} is inside its verification
          window until #{DateTime.to_iso8601(retire_after)}; removing it
          now would invalidate still-live tokens. Wait, or — only for a
          compromised key — use remove_compromised!/1.
          """
        end

      %Key{} ->
        nil
    end)
  end

  @doc """
  EMERGENCY removal that bypasses the verification window — for a
  compromised key whose public half must leave the JWKS immediately,
  accepting that still-live tokens signed with it die. Still refuses
  the active signer (rotate or rotate_compromised! first).
  """
  @spec remove_compromised!(String.t()) :: :ok
  def remove_compromised!(kid) when is_binary(kid) do
    delete_locked!(kid, fn
      %Key{status: "signing"} ->
        """
        Comma OAuth IdP key #{inspect(kid)} is the active signer; replace
        it first (rotate_compromised!/0 deletes it in the same
        transaction).
        """

      %Key{} ->
        nil
    end)
  end

  # Locks the row, applies the caller's veto inside the same transaction
  # (so a concurrent activate!/0 holding the row blocks us, and our
  # delete cannot interleave with its promote), then deletes.
  defp delete_locked!(kid, veto) do
    Repo.transaction(fn ->
      case Repo.one(from(k in Key, where: k.kid == ^kid, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback({:missing, kid})

        %Key{} = key ->
          case veto.(key) do
            nil -> Repo.delete!(key)
            message -> Repo.rollback({:vetoed, message})
          end
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, {:missing, kid}} -> raise "Comma OAuth IdP key #{inspect(kid)} does not exist"
      {:error, {:vetoed, message}} -> raise message
    end
  end

  @doc "Lists the key set for operator inspection (no private material)."
  @spec list() :: [map()]
  def list do
    Repo.all(from(k in Key, order_by: [asc: k.created_at]))
    |> Enum.map(
      &%{kid: &1.kid, status: &1.status, retire_after: &1.retire_after, created_at: &1.created_at}
    )
  end

  defp prepublish_seconds do
    config = Application.get_env(:comma_core, :oauth_idp) || []
    config[:rotation_prepublish_seconds] || @default_prepublish_seconds
  end

  defp generate_kid do
    "comma-idp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end

  defp encrypt_private_pem!(private_pem) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, kek!(), iv, private_pem, @aad, true)

    {ciphertext, iv, tag}
  end

  defp decrypt_private_pem!(%Key{} = key) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           kek!(),
           key.private_pem_iv,
           key.private_pem_ciphertext,
           @aad,
           key.private_pem_tag,
           false
         ) do
      plaintext when is_binary(plaintext) ->
        plaintext

      :error ->
        raise """
        Comma OAuth IdP key #{inspect(key.kid)} failed authenticated
        decryption: the configured KEK does not match the one that
        encrypted this key.
        """
    end
  end

  defp kek! do
    config = Application.get_env(:comma_core, :oauth_idp) || []

    case config[:kek] do
      kek when is_binary(kek) and byte_size(kek) == 32 ->
        kek

      _other ->
        raise """
        Comma OAuth IdP key-encryption key is not configured. Set
        COMMA_OAUTH_IDP_KEK to 32 bytes (base64) in the environment's
        comma-oauth-idp Secret Manager entry. The IdP fails closed
        without it.
        """
    end
  end
end
