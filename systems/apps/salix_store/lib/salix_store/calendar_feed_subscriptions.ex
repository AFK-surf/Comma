defmodule SalixStore.CalendarFeedSubscriptions do
  @moduledoc """
  Transactional Postgres storage for private iCal feed bearer credentials.

  A row owns one bearer secret granting an exact `principal_ref` subject a
  read-only view of one Comma Calendar. Only a domain-separated digest of the
  secret is stored; the plaintext secret is returned once at issuance and never
  again. Issuance rejects a second active subscription for the same
  `{tenant, group, calendar, subject}`; rotation replaces the digest; revocation
  is explicit and checked on every authentication. The row carries no foreign
  key to Comma/BFT user tables or to object-stored Calendar records.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias SalixStore.{Ids, Repo}

  @digest_domain "comma-calendar-feed/v1"
  @secret_bytes 32
  @token_digest_index :calendar_feed_subscriptions_token_digest_index
  @active_subject_index :calendar_feed_subscriptions_active_subject_idx

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "calendar_feed_subscriptions" do
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:calendar_id, :string)
      field(:subject_namespace, :string)
      field(:subject_id, :string)
      field(:token_digest, :binary)
      field(:revoked_at, :utc_datetime_usec)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  @subject_keys ~w(subject_namespace subject_id)

  @doc """
  Issue one active feed subscription for an exact owner subject and calendar.

  Returns `{:ok, %{"id" => cfd_id, "secret" => plaintext}}` exactly once. The
  plaintext secret is never persisted or recoverable. A second active
  subscription for the same subject/calendar is rejected.
  """
  @spec issue(map(), integer()) :: {:ok, map()} | {:error, term()}
  def issue(%{} = scope, now) when is_integer(now) do
    with {:ok, subject} <- validated_subject(scope) do
      secret = mint_secret()
      at = datetime(now)

      changeset =
        Changeset.change(%Row{}, %{
          id: Ids.new_calendar_feed_id(),
          tenant_id: scope["tenant_id"],
          group_id: scope["group_id"],
          calendar_id: scope["calendar_id"],
          subject_namespace: subject["subject_namespace"],
          subject_id: subject["subject_id"],
          token_digest: digest(secret),
          revoked_at: nil,
          created_at: at,
          updated_at: at
        })
        |> Changeset.unique_constraint(:token_digest, name: @token_digest_index)
        |> Changeset.unique_constraint(:id,
          name: @active_subject_index,
          message: "active subscription exists"
        )

      case Repo.insert(changeset) do
        {:ok, %Row{} = row} -> {:ok, %{"id" => row.id, "secret" => secret}}
        {:error, %Changeset{errors: errors}} -> {:error, insert_error(errors)}
      end
    end
  end

  @doc """
  The active subscription for an exact subject, if any: its public id and an
  opaque `fence` (the caller passes it back to `rotate_to/4` unchanged).
  """
  @spec active(map()) :: {:ok, map()} | {:error, term()}
  def active(%{} = scope) do
    with {:ok, subject} <- validated_subject(scope) do
      case active_row(scope, subject) do
        %Row{id: id, token_digest: digest} ->
          {:ok, %{"id" => id, "fence" => Base.encode16(digest)}}

        nil ->
          {:error, :not_found}
      end
    end
  end

  @doc "Mint a fresh plaintext feed secret without persisting anything."
  @spec new_secret() :: String.t()
  def new_secret, do: mint_secret()

  @doc """
  Rotate an active subscription's secret, only if it still matches the observed
  `fence`.

  A single atomic compare-and-swap: it commits the replacement exactly when the
  row is unchanged since the request observed it, so a concurrent reissue can
  never invalidate a secret another caller has already returned to its owner.
  """
  @spec rotate_to(String.t(), String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def rotate_to(feed_id, fence, secret, now)
      when is_binary(feed_id) and is_binary(fence) and is_binary(secret) and is_integer(now) do
    with {:ok, expected} <- decode_fence(fence) do
      {count, _} =
        Repo.update_all(
          from(r in Row,
            where: r.id == ^feed_id and r.token_digest == ^expected and is_nil(r.revoked_at)
          ),
          set: [token_digest: digest(secret), updated_at: datetime(now)]
        )

      if count == 1, do: :ok, else: {:error, :calendar_feed_stale}
    end
  end

  defp decode_fence(fence) do
    case Base.decode16(fence) do
      {:ok, expected} -> {:ok, expected}
      :error -> {:error, :invalid_fence}
    end
  end

  @doc """
  Authenticate a feed request by public id and plaintext secret.

  Loads the exact row, rejects revoked subscriptions, and compares the secret
  digest in constant time. On success returns the owner scope needed to query
  the Calendar; the digest and secret never leave this module.
  """
  @spec authenticate(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def authenticate(feed_id, secret) when is_binary(feed_id) and is_binary(secret) do
    with true <- Ids.valid_calendar_feed_id?(feed_id) or {:error, :not_found},
         %Row{} = row <- Repo.get(Row, feed_id) || {:error, :not_found},
         :active <- revocation_state(row) do
      if constant_time_equal?(row.token_digest, digest(secret)) do
        {:ok, scope(row)}
      else
        {:error, :unauthorized}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def authenticate(_feed_id, _secret), do: {:error, :not_found}

  @doc "Revoke a subscription. Idempotent; a revoked row stays revoked."
  @spec revoke(String.t(), integer()) :: :ok | {:error, term()}
  def revoke(feed_id, now) when is_binary(feed_id) and is_integer(now) do
    transaction_result(fn ->
      case locked(feed_id) do
        nil ->
          Repo.rollback(:not_found)

        %Row{revoked_at: nil} = row ->
          row
          |> Changeset.change(%{revoked_at: datetime(now), updated_at: datetime(now)})
          |> Repo.update!()

          :ok

        %Row{} ->
          :ok
      end
    end)
  end

  @doc """
  Rotate an active subscription's secret in place, invalidating the old URL.

  Returns `{:ok, %{"secret" => plaintext}}` once. A revoked or missing row is
  rejected rather than silently re-activated.
  """
  @spec rotate(String.t(), integer()) :: {:ok, map()} | {:error, term()}
  def rotate(feed_id, now) when is_binary(feed_id) and is_integer(now) do
    secret = mint_secret()

    result =
      transaction_result(fn ->
        case locked(feed_id) do
          nil ->
            Repo.rollback(:not_found)

          %Row{revoked_at: nil} = row ->
            row
            |> Changeset.change(%{token_digest: digest(secret), updated_at: datetime(now)})
            |> Repo.update!()

            :ok

          %Row{} ->
            Repo.rollback(:calendar_feed_revoked)
        end
      end)

    case result do
      :ok -> {:ok, %{"secret" => secret}}
      {:error, _} = error -> error
    end
  end

  @doc "Read subscription metadata for owner UI. Never returns the digest or secret."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(feed_id) when is_binary(feed_id) do
    case Repo.get(Row, feed_id) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  end

  defp validated_subject(%{} = scope) do
    subject = Map.take(scope, @subject_keys)

    cond do
      not present?(scope["tenant_id"]) -> {:error, :invalid_scope}
      not present?(scope["group_id"]) -> {:error, :invalid_scope}
      not present?(scope["calendar_id"]) -> {:error, :invalid_scope}
      not Enum.all?(@subject_keys, &present?(subject[&1])) -> {:error, :invalid_subject}
      true -> {:ok, subject}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp insert_error(errors) do
    cond do
      Keyword.has_key?(errors, :id) -> :calendar_feed_active_exists
      Keyword.has_key?(errors, :token_digest) -> :calendar_feed_token_collision
      true -> :calendar_feed_conflict
    end
  end

  defp revocation_state(%Row{revoked_at: nil}), do: :active
  defp revocation_state(%Row{}), do: {:error, :revoked}

  defp mint_secret,
    do: :crypto.strong_rand_bytes(@secret_bytes) |> Base.url_encode64(padding: false)

  defp digest(secret), do: :crypto.hash(:sha256, @digest_domain <> <<0>> <> secret)

  # :crypto.hash_equals/2 raises on a length mismatch; both operands here are
  # fixed 32-byte SHA-256 outputs, and the DB CHECK guarantees the stored side.
  defp constant_time_equal?(left, right)
       when byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp constant_time_equal?(_left, _right), do: false

  defp active_row(scope, subject) do
    Repo.one(
      from(r in Row,
        where:
          r.tenant_id == ^scope["tenant_id"] and r.group_id == ^scope["group_id"] and
            r.calendar_id == ^scope["calendar_id"] and
            r.subject_namespace == ^subject["subject_namespace"] and
            r.subject_id == ^subject["subject_id"] and is_nil(r.revoked_at)
      )
    )
  end

  defp locked(feed_id) do
    Repo.one(from(r in Row, where: r.id == ^feed_id, lock: "FOR UPDATE"))
  end

  defp transaction_result(fun) do
    case Repo.transaction(fun) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp scope(%Row{} = row) do
    %{
      "id" => row.id,
      "tenant_id" => row.tenant_id,
      "group_id" => row.group_id,
      "calendar_id" => row.calendar_id,
      "subject_namespace" => row.subject_namespace,
      "subject_id" => row.subject_id
    }
  end

  defp to_record(%Row{} = row) do
    row
    |> scope()
    |> Map.put("created_at", millis(row.created_at))
    |> Map.put("updated_at", millis(row.updated_at))
    |> put_optional("revoked_at", millis(row.revoked_at))
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp datetime(ms) when is_integer(ms), do: DateTime.from_unix!(ms * 1_000, :microsecond)
  defp millis(nil), do: nil
  defp millis(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
end
