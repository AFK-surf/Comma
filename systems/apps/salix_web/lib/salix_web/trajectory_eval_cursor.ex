defmodule SalixWeb.TrajectoryEvalCursor do
  @moduledoc false

  @domain "salix-trajectory-eval-results-cursor-v1"

  @spec encode(String.t(), map()) :: {:ok, String.t()} | {:error, :unavailable}
  def encode(tenant_id, state) when is_binary(tenant_id) and is_map(state) do
    with {:ok, key} <- signing_key() do
      payload =
        state
        |> Map.put("v", 1)
        |> Map.put("tenant", tenant_hash(tenant_id))
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      signature =
        :crypto.mac(:hmac, :sha256, key, payload)
        |> Base.url_encode64(padding: false)

      {:ok, payload <> "." <> signature}
    end
  end

  @spec decode(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid | :unavailable}
  def decode(token, tenant_id) when is_binary(token) and is_binary(tenant_id) do
    with {:ok, key} <- signing_key(),
         [payload, encoded_signature] <- String.split(token, ".", parts: 2),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         expected <- :crypto.mac(:hmac, :sha256, key, payload),
         true <- :crypto.hash_equals(expected, signature),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"v" => 1, "tenant" => tenant} = state} <- Jason.decode(json),
         true <- tenant == tenant_hash(tenant_id),
         true <- valid_state?(state) do
      {:ok, state}
    else
      {:error, :unavailable} = error -> error
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  def decode(_token, _tenant_id), do: {:error, :invalid}

  defp valid_state?(state) do
    valid_time?(state["after_at"]) and is_binary(state["after_key"]) and
      valid_time?(state["snapshot_to"]) and is_boolean(state["complete"]) and
      is_map(state["filters"])
  end

  defp valid_time?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_time?(_), do: false

  defp signing_key do
    secret =
      Application.get_env(:salix_web, :trajectory_eval_cursor_secret) ||
        Application.get_env(:salix_web, :api_token)

    if is_binary(secret) and secret != "" do
      {:ok, :crypto.mac(:hmac, :sha256, secret, @domain)}
    else
      {:error, :unavailable}
    end
  end

  defp tenant_hash(tenant_id) do
    :crypto.hash(:sha256, tenant_id)
    |> Base.encode16(case: :lower)
  end
end
