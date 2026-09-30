defmodule SalixStore.Config do
  @moduledoc """
  Storage-layer configuration: S3 endpoint, credentials, bucket, and the
  active S3 backend implementation.

  Resolved from application env (`:salix_store`) so the same release talks to
  MinIO in dev/test and real S3 in prod. All values are read at call time
  (cheap) so tests can reconfigure freely.
  """

  @type t :: %__MODULE__{
          endpoint: String.t(),
          region: String.t(),
          bucket: String.t(),
          access_key_id: String.t(),
          secret_access_key: String.t(),
          # path-style is required for MinIO and dev; virtual-host for real S3
          addressing: :path | :virtual_host,
          atomic_operations: :s3 | :gcp
        }

  defstruct [
    :endpoint,
    :region,
    :bucket,
    :access_key_id,
    :secret_access_key,
    addressing: :path,
    atomic_operations: :s3
  ]

  @doc "Build the active S3 config from app env."
  @spec get() :: t()
  def get do
    env = Application.get_all_env(:salix_store)

    %__MODULE__{
      endpoint: pick(env, :s3_endpoint, "http://127.0.0.1:19000"),
      region: pick(env, :s3_region, "us-east-1"),
      bucket: pick(env, :s3_bucket, "salix-dev"),
      access_key_id: pick(env, :s3_access_key_id, "minioadmin"),
      secret_access_key: pick(env, :s3_secret_access_key, "minioadmin"),
      addressing: Keyword.get(env, :s3_addressing, :path),
      atomic_operations: pick(env, :s3_atomic_operations, :s3) |> normalize_atomic_operations()
    }
  end

  @doc "The active S3 backend module (real AWS/MinIO or the in-memory fake)."
  @spec backend() :: module()
  def backend do
    Application.get_env(:salix_store, :s3_backend, SalixStore.S3.AWS)
  end

  @doc """
  Conditional-DELETE strategy.

    * `:native`  — send `If-Match` on DELETE (real AWS S3, MinIO ≥ the version
      that added conditional deletes).
    * `:emulate` — HEAD-compare-then-delete (portable; the MinIO release we test
      against does not enforce `If-Match` on DELETE). Carries a small TOCTOU
      window whose exposure differs per marker family — participant wakeup
      markers have no repairing sweep (the agent queue-marker family and its
      recent-touch backstop retired with A2 §3.4). The authoritative
      per-family pricing is the "Wakeup marker 的 ETag 语义" section of
      `docs/storage-search.md`; do not restate it
      at call sites.

  Defaults to `:emulate` because the dev/test target is MinIO; production sets
  `:native` via config.json/app config.
  """
  @spec conditional_delete() :: :native | :emulate
  def conditional_delete do
    case Application.get_env(:salix_store, :s3_conditional_delete, :emulate) do
      :native -> :native
      _ -> :emulate
    end
  end

  defp pick(env, key, default) do
    Keyword.get(env, key, default)
  end

  defp normalize_atomic_operations(:gcp), do: :gcp
  defp normalize_atomic_operations("gcp"), do: :gcp
  defp normalize_atomic_operations(_), do: :s3
end
