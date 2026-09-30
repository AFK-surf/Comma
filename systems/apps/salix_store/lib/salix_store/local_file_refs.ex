defmodule SalixStore.LocalFileRefs do
  @moduledoc """
  Transactional Postgres storage for opaque local-file routing records.

  Rows are keyed by a one-way ref digest. The opaque ref itself, host paths,
  and file bytes are never stored here. State transitions lock the row and
  admit only the registered/bound/revoked lifecycle before terminal
  retirement; cleanup is bounded and uses the expiry index. Expiry scrubs
  route metadata into a compact `retired` digest
  tombstone instead of deleting the primary key, so an opaque ref can never be
  registered or bound a second time.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias SalixStore.{Crypto, Repo}

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:ref_digest, :string, autogenerate: false}
    schema "local_file_refs" do
      field(:version, :integer)
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:owner_user_id, :string)
      field(:stable_device_id, :string)
      field(:state, :string)
      field(:conversation_id, :string)
      field(:message_id, :string)
      field(:created_at, :utc_datetime_usec)
      field(:expires_at, :utc_datetime_usec)
      field(:bound_at, :utc_datetime_usec)
      field(:revoked_at, :utc_datetime_usec)
      field(:retired_at, :utc_datetime_usec)
    end
  end

  @registration_keys ~w(version tenant_id group_id owner_user_id stable_device_id state)

  @spec ref_digest(String.t()) :: String.t()
  def ref_digest(ref) when is_binary(ref), do: Crypto.hex(ref)

  @spec insert_registration(map()) :: {:ok, map()} | {:error, term()}
  def insert_registration(%{"local_file_ref" => ref, "state" => "registered"} = record)
      when is_binary(ref) do
    row = registration_row(record)

    case Repo.insert(row, on_conflict: :nothing, conflict_target: :ref_digest) do
      {:ok, %Row{}} ->
        case get(ref) do
          {:ok, existing} -> require_same_registration(existing, record)
          {:error, _} = error -> error
        end

      {:error, _changeset} ->
        {:error, :local_file_ref_conflict}
    end
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(ref) when is_binary(ref) do
    case Repo.get(Row, ref_digest(ref)) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row, ref)}
    end
  end

  @doc "Atomically bind one live registered ref to one exact canonical message."
  @spec bind(String.t(), String.t(), String.t(), String.t(), String.t(), integer(), integer()) ::
          :ok | {:error, term()}
  def bind(ref, group_id, conversation_id, message_id, owner_user_id, now, bound_expires_at)
      when is_binary(ref) and is_integer(now) and is_integer(bound_expires_at) do
    transaction_result(fn ->
      case locked(ref) do
        nil ->
          Repo.rollback(:not_found)

        %Row{} = row ->
          cond do
            row.state == "revoked" ->
              Repo.rollback(:local_file_unavailable)

            row.group_id != group_id or row.owner_user_id != owner_user_id ->
              Repo.rollback(:local_file_unavailable)

            active_expired?(row, now) ->
              Repo.rollback(:local_file_unavailable)

            row.state == "registered" ->
              row
              |> Changeset.change(%{
                state: "bound",
                conversation_id: conversation_id,
                message_id: message_id,
                bound_at: datetime(now),
                expires_at: datetime(bound_expires_at)
              })
              |> Repo.update!()

              :ok

            row.state == "bound" and row.conversation_id == conversation_id and
                row.message_id == message_id ->
              :ok

            true ->
              Repo.rollback(:local_file_ref_conflict)
          end
      end
    end)
  end

  @doc "Atomically revoke a route without changing its binding identity."
  @spec revoke(String.t(), String.t(), String.t(), String.t(), integer()) ::
          :ok | {:error, term()}
  def revoke(ref, group_id, owner_user_id, device_id, now)
      when is_binary(ref) and is_integer(now) do
    transaction_result(fn ->
      case locked(ref) do
        nil ->
          Repo.rollback(:not_found)

        %Row{} = row ->
          if row.group_id == group_id and row.owner_user_id == owner_user_id and
               row.stable_device_id == device_id do
            if row.state != "revoked" do
              row
              |> Changeset.change(%{state: "revoked", revoked_at: datetime(now)})
              |> Repo.update!()
            end

            :ok
          else
            Repo.rollback(:local_file_unavailable)
          end
      end
    end)
  end

  @doc "Retire at most `:limit` expired routes while preserving non-reusable ref digests."
  @spec cleanup_expired(integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_expired(now, opts \\ []) when is_integer(now) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, 1_000) |> bounded_limit()
    cutoff = datetime(now)

    case Repo.transaction(fn ->
           digests =
             Row
             |> where(
               [r],
               r.state in ["registered", "bound", "revoked"] and r.expires_at <= ^cutoff
             )
             |> order_by([r], asc: r.expires_at, asc: r.ref_digest)
             |> limit(^limit)
             |> lock("FOR UPDATE SKIP LOCKED")
             |> select([r], r.ref_digest)
             |> Repo.all()

           if digests == [] do
             0
           else
             {count, _} =
               Row
               |> where(
                 [r],
                 r.ref_digest in ^digests and
                   r.state in ["registered", "bound", "revoked"] and
                   r.expires_at <= ^cutoff
               )
               |> Repo.update_all(
                 set: [
                   state: "retired",
                   tenant_id: "",
                   group_id: "",
                   owner_user_id: "",
                   stable_device_id: "",
                   conversation_id: nil,
                   message_id: nil,
                   bound_at: nil,
                   revoked_at: nil,
                   retired_at: cutoff
                 ]
               )

             count
           end
         end) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp locked(ref) do
    Repo.one(from(r in Row, where: r.ref_digest == ^ref_digest(ref), lock: "FOR UPDATE"))
  end

  defp transaction_result(fun) do
    case Repo.transaction(fun) do
      {:ok, :ok} -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_same_registration(existing, expected) do
    if Map.take(existing, @registration_keys) == Map.take(expected, @registration_keys) and
         existing["state"] == "registered" do
      {:ok, existing}
    else
      {:error, :local_file_ref_conflict}
    end
  end

  defp registration_row(record) do
    %Row{
      ref_digest: ref_digest(record["local_file_ref"]),
      version: record["version"],
      tenant_id: record["tenant_id"],
      group_id: record["group_id"],
      owner_user_id: record["owner_user_id"],
      stable_device_id: record["stable_device_id"],
      state: "registered",
      created_at: datetime(record["created_at"]),
      expires_at: datetime(record["expires_at"])
    }
  end

  defp to_record(%Row{} = row, ref) do
    %{
      "version" => row.version,
      "local_file_ref" => ref,
      "tenant_id" => row.tenant_id,
      "group_id" => row.group_id,
      "owner_user_id" => row.owner_user_id,
      "stable_device_id" => row.stable_device_id,
      "state" => row.state,
      "created_at" => millis(row.created_at),
      "expires_at" => millis(row.expires_at)
    }
    |> put_optional("conversation_id", row.conversation_id)
    |> put_optional("message_id", row.message_id)
    |> put_optional("bound_at", millis(row.bound_at))
    |> put_optional("revoked_at", millis(row.revoked_at))
    |> put_optional("retired_at", millis(row.retired_at))
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp active_expired?(%Row{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, datetime(now)) != :gt

  defp datetime(ms) when is_integer(ms), do: DateTime.from_unix!(ms * 1_000, :microsecond)
  defp millis(nil), do: nil
  defp millis(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

  defp bounded_limit(value) when is_integer(value) and value > 0, do: min(value, 10_000)
  defp bounded_limit(_), do: 1_000
end
