defmodule SalixStore.TriageRecordStore do
  @moduledoc """
  Runtime dispatcher for the native-Triage record backend.

  Production defaults to `SalixStore.TriageRecords`, which maps the closed
  logical key family onto typed PostgreSQL tables. Tests may inject the
  fault-capable S3 fake while the typed adapter and atomic terminal transaction
  are exercised by their integration suite.
  """

  alias SalixStore.{TriageKeys, TriageRecords}

  def owned?(key), do: TriageKeys.owned?(key)

  def put(key, body, opts \\ []), do: backend().put(key, body, opts)
  def get(key, opts \\ []), do: backend().get(key, opts)

  def get_bounded(key, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    backend = backend()

    if supports?(backend, :get_bounded, 2) do
      backend.get_bounded(key, max_bytes)
    else
      bounded_range_get(backend, key, max_bytes)
    end
  end

  def get_bounded(_key, _max_bytes), do: {:error, :invalid}

  @doc "Batched `get_bounded/2` when the backend supports it; see `TriageRecords.get_bounded_many/2`."
  def get_bounded_many(keys, max_total_bytes) do
    backend = backend()

    if supports?(backend, :get_bounded_many, 2),
      do: backend.get_bounded_many(keys, max_total_bytes),
      else: {:error, :unsupported}
  end

  def head(key), do: backend().head(key)
  def delete(key, opts \\ []), do: backend().delete(key, opts)
  def list(prefix, opts \\ []), do: backend().list(prefix, opts)

  def recovery_page(prefix, opts) do
    backend = backend()

    if supports?(backend, :recovery_page, 2),
      do: backend.recovery_page(prefix, opts),
      else: {:error, :unsupported}
  end

  def atomic_authoritative? do
    backend = backend()
    supports?(backend, :commit_authoritative, 1)
  end

  def admit_receipt(admission) do
    backend = backend()

    if supports?(backend, :admit_receipt, 1),
      do: backend.admit_receipt(admission),
      else: {:error, :unsupported}
  end

  def record_intent_settlement(settlement) do
    backend = backend()

    if supports?(backend, :record_intent_settlement, 1),
      do: backend.record_intent_settlement(settlement),
      else: SalixStore.TriageTransactions.record_intent_settlement(settlement)
  end

  def commit_authoritative(commit) do
    backend = backend()

    if supports?(backend, :commit_authoritative, 1),
      do: backend.commit_authoritative(commit),
      else: {:error, :unsupported}
  end

  def list_all(prefix, opts \\ []) do
    backend = backend()

    if supports?(backend, :list_all, 2) do
      backend.list_all(prefix, opts)
    else
      do_list_all(backend, prefix, opts, [])
    end
  end

  defp do_list_all(backend, prefix, opts, acc) do
    case backend.list(prefix, opts) do
      {:ok, %{objects: objects, next: nil}} ->
        {:ok, acc ++ objects}

      {:ok, %{objects: objects, next: token}} ->
        do_list_all(
          backend,
          prefix,
          Keyword.put(opts, :continuation_token, token),
          acc ++ objects
        )

      {:error, _reason} = error ->
        error
    end
  end

  # A ranged GET is the compatibility boundary for the fault-capable S3 test
  # backend. Asking for one byte past the limit distinguishes an exact fit from
  # an oversized body without ever transferring the complete oversized record.
  defp bounded_range_get(backend, key, max_bytes) do
    case backend.get(key, range: {0, max_bytes + 1}) do
      {:ok, %{body: body} = result} when byte_size(body) <= max_bytes ->
        {:ok, Map.put(result, :size, byte_size(body))}

      {:ok, %{body: body}} when byte_size(body) > max_bytes ->
        {:error, :too_large}

      {:error, _reason} = error ->
        error
    end
  end

  defp backend,
    do: Application.get_env(:salix_store, :triage_record_backend, TriageRecords)

  defp supports?(backend, function, arity),
    do: Code.ensure_loaded?(backend) and function_exported?(backend, function, arity)
end
