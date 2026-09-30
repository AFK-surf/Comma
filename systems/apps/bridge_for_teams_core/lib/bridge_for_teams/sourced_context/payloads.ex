defmodule BridgeForTeams.SourcedContext.Payloads do
  @moduledoc false

  alias BridgeForTeams.SourcedContext.{CanonicalJSON, Crypto}

  @type kind :: :artifact | :review_item

  @spec seal(kind(), Ecto.UUID.t(), map()) ::
          {:ok, %{ciphertext: String.t(), sha256: String.t()}} | {:error, term()}
  def seal(kind, id, payload) when kind in [:artifact, :review_item] and is_map(payload) do
    with {:ok, bytes} <- CanonicalJSON.encode(payload),
         {:ok, ciphertext} <- Crypto.seal(bytes, aad(kind, id)) do
      {:ok, %{ciphertext: ciphertext, sha256: CanonicalJSON.sha256(bytes)}}
    end
  end

  def seal(_kind, _id, _payload), do: {:error, :invalid_sourced_context_payload}

  @spec unseal(kind(), Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def unseal(kind, id, ciphertext, expected_sha256)
      when kind in [:artifact, :review_item] and is_binary(ciphertext) and
             is_binary(expected_sha256) do
    with {:ok, bytes} <- Crypto.unseal(ciphertext, aad(kind, id)),
         true <- CanonicalJSON.sha256(bytes) == expected_sha256,
         {:ok, payload} when is_map(payload) <- Jason.decode(bytes) do
      {:ok, payload}
    else
      _invalid -> {:error, :sourced_context_payload_integrity_failed}
    end
  end

  def unseal(_kind, _id, _ciphertext, _expected_sha256),
    do: {:error, :sourced_context_payload_integrity_failed}

  defp aad(:artifact, id), do: "artifact:#{id}"
  defp aad(:review_item, id), do: "review-item:#{id}"
end
