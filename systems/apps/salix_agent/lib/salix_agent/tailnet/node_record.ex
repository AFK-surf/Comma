defmodule SalixAgent.Tailnet.NodeRecord do
  @moduledoc """
  The lease record of a Group's tailnet node, at
  `SalixStore.Keys.ctl_group_tailnet_node/1`.

  One object holds both the lease (`holder`, `epoch`, `lease_until`) and the
  node's body: its `tsnet` state (machine and node private keys) and its last
  status. So every body write is a lease renewal, fenced by the object's
  ETag: a holder that lost the lease can never overwrite a newer node key.
  This is the `SalixCluster.S3Lease` protocol (tla/salix/Lease.tla: at most
  one valid ETag token) with a payload. Safety depends only on the ETag;
  `lease_until` decides only when another node may take over.

  The body is sealed with AES-256-GCM under the deployment credential root
  (`SalixStore.Crypto.derived_key/1`, purpose `group-tailnet-node-v1`), with
  the Group in the AAD. Release keeps the body, so the next holder restores
  the same node.

  Each saved change emits `[:salix, :tailnet, :node_record]` with the
  `group_id`: the Group's projected status may have changed.
  """

  alias SalixStore.{Crypto, Keys, S3}

  @purpose "group-tailnet-node-v1"
  @ttl_ms 30_000

  defstruct [:group_id, :holder, :epoch, :etag, :lease_until, body: %{}]

  @type t :: %__MODULE__{
          group_id: String.t(),
          holder: String.t(),
          epoch: pos_integer(),
          etag: String.t(),
          lease_until: integer(),
          body: map()
        }

  @doc "How long a lease lasts without renewal."
  def ttl_ms, do: @ttl_ms

  @doc """
  The record without taking the lease: `holder` (nil when released), `epoch`,
  `lease_until` and the unsealed `body`.
  """
  @spec read(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def read(group_id) do
    with {:ok, %{body: raw}} <- S3.get(Keys.ctl_group_tailnet_node(group_id)),
         {:ok, record} <- decode(group_id, raw) do
      {:ok, record}
    end
  end

  @doc """
  Take the lease when nobody holds it, it expired, or `holder` already holds
  it. Returns `{:error, {:held_by, holder, lease_until}}` otherwise.
  """
  @spec acquire(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def acquire(group_id, holder, opts \\ []) do
    now = opts[:now] || now_ms()
    key = Keys.ctl_group_tailnet_node(group_id)

    case S3.get(key) do
      {:error, :not_found} ->
        take(group_id, holder, 1, %{}, [if_none_match: "*"], now, opts)

      {:ok, %{body: raw, etag: etag}} ->
        with {:ok, current} <- decode(group_id, raw) do
          if current["holder"] in [nil, holder] or current["lease_until"] <= now do
            take(
              group_id,
              holder,
              current["epoch"] + 1,
              current["body"],
              [if_match: etag],
              now,
              opts
            )
          else
            {:error, {:held_by, current["holder"], current["lease_until"]}}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Renew the lease and replace the body. `{:error, :lost}` means another
  holder took the lease: stop acting as the owner at once.
  """
  @spec write(t(), map()) :: {:ok, t()} | {:error, :lost | term()}
  def write(%__MODULE__{} = lease, body) when is_map(body) do
    lease_until = now_ms() + @ttl_ms

    with {:ok, raw} <- encode(lease.group_id, lease.holder, lease.epoch, lease_until, body) do
      case S3.put(Keys.ctl_group_tailnet_node(lease.group_id), raw, if_match: lease.etag) do
        {:ok, %{etag: etag}} ->
          saved(lease.group_id)
          {:ok, %{lease | etag: etag, lease_until: lease_until, body: body}}

        {:error, :precondition_failed} ->
          {:error, :lost}

        {:error, {:ambiguous, _}} ->
          verify(lease, lease_until, body)

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "Release the lease and keep the body for the next holder. Best effort."
  @spec release(t()) :: :ok
  def release(%__MODULE__{} = lease) do
    with {:ok, raw} <- encode(lease.group_id, nil, lease.epoch, 0, lease.body) do
      case S3.put(Keys.ctl_group_tailnet_node(lease.group_id), raw, if_match: lease.etag) do
        {:ok, _} -> saved(lease.group_id)
        _ -> :ok
      end
    end

    :ok
  end

  @doc false
  def delete(group_id), do: S3.delete(Keys.ctl_group_tailnet_node(group_id))

  @doc "The node name in a holder, or nil."
  def holder_node(nil), do: nil
  def holder_node(holder) when is_binary(holder), do: holder |> String.split("|") |> hd()

  @doc "Whether a read record has a live holder."
  def live?(%{"holder" => holder, "lease_until" => until}, now \\ now_ms()),
    do: is_binary(holder) and is_integer(until) and until > now

  defp take(group_id, holder, epoch, body, condition, now, opts) do
    lease_until = now + (opts[:ttl_ms] || @ttl_ms)

    with {:ok, raw} <- encode(group_id, holder, epoch, lease_until, body) do
      case S3.put(Keys.ctl_group_tailnet_node(group_id), raw, condition) do
        {:ok, %{etag: etag}} ->
          saved(group_id)

          {:ok,
           %__MODULE__{
             group_id: group_id,
             holder: holder,
             epoch: epoch,
             etag: etag,
             lease_until: lease_until,
             body: body
           }}

        # Another node took it first; the caller routes to that holder.
        {:error, :precondition_failed} ->
          case read(group_id) do
            {:ok, current} -> {:error, {:held_by, current["holder"], current["lease_until"]}}
            _ -> {:error, {:held_by, nil, nil}}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  # An ambiguous write either landed or not. The holder is unique to one
  # owner process, so our holder and epoch with our body means it landed.
  defp verify(lease, lease_until, body) do
    with {:ok, %{body: raw, etag: etag}} <- S3.get(Keys.ctl_group_tailnet_node(lease.group_id)),
         {:ok, %{"holder" => holder, "epoch" => epoch, "body" => ^body}} <-
           decode(lease.group_id, raw),
         true <- holder == lease.holder and epoch == lease.epoch do
      saved(lease.group_id)
      {:ok, %{lease | etag: etag, lease_until: lease_until, body: body}}
    else
      _ -> {:error, :lost}
    end
  end

  defp saved(group_id),
    do:
      SystemsRuntime.Telemetry.execute([:salix, :tailnet, :node_record], %{count: 1}, %{
        group_id: group_id
      })

  defp encode(group_id, holder, epoch, lease_until, body) do
    with {:ok, sealed} <- seal(group_id, Jason.encode!(body)) do
      {:ok,
       Jason.encode!(%{
         "holder" => holder,
         "epoch" => epoch,
         "lease_until" => lease_until,
         "body" => sealed
       })}
    end
  end

  defp decode(group_id, raw) do
    with {:ok, %{"epoch" => epoch, "lease_until" => until, "body" => sealed} = record}
         when is_integer(epoch) and is_integer(until) <- Jason.decode(raw),
         {:ok, json} <- unseal(group_id, sealed),
         {:ok, body} when is_map(body) <- Jason.decode(json) do
      {:ok,
       %{"holder" => record["holder"], "epoch" => epoch, "lease_until" => until, "body" => body}}
    else
      {:error, :credential_sealer_unavailable} = error -> error
      _ -> {:error, :invalid_tailnet_node_record}
    end
  end

  defp aad(group_id), do: Jason.encode!([@purpose, group_id])

  defp seal(group_id, plaintext) do
    with {:ok, key} <- Crypto.derived_key(@purpose) do
      iv = SystemsRuntime.Proc.random_bytes(12)

      {cipher, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad(group_id), true)

      {:ok, "v1." <> Base.url_encode64(iv <> tag <> cipher, padding: false)}
    end
  end

  defp unseal(group_id, "v1." <> encoded) do
    with {:ok, key} <- Crypto.derived_key(@purpose),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), cipher::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, aad(group_id), tag, false) do
      {:ok, plaintext}
    else
      {:error, :credential_sealer_unavailable} = error -> error
      _ -> {:error, :invalid_tailnet_node_record}
    end
  end

  defp unseal(_group_id, _sealed), do: {:error, :invalid_tailnet_node_record}

  defp now_ms, do: SystemsClock.system_time(:millisecond)
end
