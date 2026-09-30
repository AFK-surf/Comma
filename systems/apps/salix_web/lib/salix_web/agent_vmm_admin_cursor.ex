defmodule SalixWeb.AgentVMMAdminCursor do
  @moduledoc false

  @domain "salix-agent-vmm-admin-cursor-v1"

  def encode(tenant_id, cursor, filters)
      when is_binary(tenant_id) and is_map(cursor) and is_map(filters) do
    with {:ok, key} <- signing_key() do
      payload =
        %{
          "v" => 1,
          "tenant" => tenant_hash(tenant_id),
          "cursor" => cursor,
          "filters" => filters
        }
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      signature =
        :crypto.mac(:hmac, :sha256, key, payload)
        |> Base.url_encode64(padding: false)

      {:ok, payload <> "." <> signature}
    end
  end

  def decode(token, tenant_id, filters)
      when is_binary(token) and byte_size(token) <= 1_000 and is_binary(tenant_id) and
             is_map(filters) do
    with {:ok, key} <- signing_key(),
         [payload, encoded_signature] <- String.split(token, ".", parts: 2),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         expected <- :crypto.mac(:hmac, :sha256, key, payload),
         true <- :crypto.hash_equals(expected, signature),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok,
          %{
            "v" => 1,
            "tenant" => tenant,
            "cursor" => cursor,
            "filters" => cursor_filters
          }} <- Jason.decode(json),
         true <- tenant == tenant_hash(tenant_id),
         true <- cursor_filters == filters,
         true <- valid_cursor?(cursor) do
      {:ok, cursor}
    else
      {:error, :unavailable} = error -> error
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  def decode(_, _, _), do: {:error, :invalid}

  defp valid_cursor?(%{"rank" => rank, "updated_at" => at, "id" => id})
       when is_integer(rank) and rank >= 0 and is_binary(at) and is_binary(id),
       do: match?({:ok, _, 0}, DateTime.from_iso8601(at))

  defp valid_cursor?(_), do: false

  defp signing_key do
    case Application.get_env(:salix_web, :api_token) do
      secret when is_binary(secret) and secret != "" ->
        {:ok, :crypto.mac(:hmac, :sha256, secret, @domain)}

      _ ->
        {:error, :unavailable}
    end
  end

  defp tenant_hash(tenant_id),
    do: :crypto.hash(:sha256, tenant_id) |> Base.encode16(case: :lower)
end
