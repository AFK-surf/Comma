defmodule Comma.AgentResources do
  @moduledoc """
  Bounded reads for immutable Agent-owned resources.

  The caller has already interpreted a canonical Salix content block and
  supplies its `blob_ref`. This module does not read, locate, or rewrite a
  Conversation Message.

  Group + Agent authorization is the access boundary. The ref hash is not a
  signature or a second authorization authority: SalixStore mints it while
  writing the immutable blob and the client carries it back as provenance.
  Comma compares it with the returned blob bytes so a corrupt, truncated, or
  mismatched store response is not rendered as the requested resource. CommaWeb
  owns this integrity check and fails the read closed as unavailable/404.
  """

  alias SalixStore.Ids

  @max_read_bytes 10_000_000
  @blob_uuid ~r/^[0-9a-f]{32}$/
  @blob_hash ~r/^[0-9a-f]{64}$/

  @spec fetch_blob(map(), String.t(), term()) :: {:ok, binary()} | {:error, term()}
  def fetch_blob(group_scope, agent_id, ref) when is_map(group_scope) do
    group_id = group_scope["default_group_id"]

    with true <- Ids.valid_agent_id_for_group?(agent_id, group_id),
         {:ok, ref} <- normalize_blob_ref(ref),
         true <- ref["size"] <= @max_read_bytes,
         {:ok, body} <-
           Comma.Salix.Client.impl().read_agent_blob(
             group_scope,
             agent_id,
             ref,
             @max_read_bytes + 1
           ),
         true <- byte_size(body) == ref["size"],
         true <- sha256(body) == ref["hash"] do
      {:ok, body}
    else
      false -> {:error, :not_found}
      {:error, :too_large} -> {:error, :not_found}
      {:error, _reason} = error -> error
      _invalid -> {:error, :resource_unavailable}
    end
  end

  def fetch_blob(_group_scope, _agent_id, _ref), do: {:error, :not_found}

  defp normalize_blob_ref(
         %{
           "kind" => "blob",
           "uuid" => uuid,
           "hash" => hash,
           "size" => size
         } = ref
       )
       when map_size(ref) == 4 and is_binary(uuid) and is_binary(hash) and is_integer(size) and
              size >= 0 do
    if Regex.match?(@blob_uuid, uuid) and Regex.match?(@blob_hash, hash) do
      {:ok, ref}
    else
      {:error, :not_found}
    end
  end

  defp normalize_blob_ref(_ref), do: {:error, :not_found}

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
