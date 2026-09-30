defmodule SalixIM.Provider.Util do
  @moduledoc false

  def ensure_connected(connect) do
    cond do
      connect["disabled_at"] != nil or connect["deleted_at"] != nil ->
        {:error, "connect not found"}

      connect["provider"] == "slack" ->
        :ok

      connect["status"] == "connected" ->
        :ok

      true ->
        {:error, "connect not found"}
    end
  end

  def read_agent_upload(agent_id, path, title \\ "") do
    path = str(path)

    if path == "" do
      {:error, "path is required"}
    else
      SalixIM.Ports.AgentWorkspace.read_upload(agent_id, path, title)
    end
  end

  def post_json(base, path, body, headers \\ []) do
    request(fn ->
      Req.post(String.trim_trailing(base, "/") <> path,
        json: body,
        headers: headers,
        retry: false
      )
    end)
  end

  def request(fun) do
    case fun.() do
      {:ok, %{status: status, body: %{"ok" => true, "result" => result}}}
      when status in 200..299 ->
        {:ok, result}

      {:ok, %{status: status, body: %{"code" => 0, "data" => data}}} when status in 200..299 ->
        {:ok, data}

      {:ok, %{status: status, body: %{"code" => 0} = body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: %{"ret" => 0} = body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{body: %{"ok" => false, "description" => desc}}} ->
        {:error, desc}

      {:ok, %{body: %{"code" => code, "msg" => msg}}} ->
        {:error, "provider API error #{code}: #{msg}"}

      {:ok, %{body: %{"ret" => ret, "errmsg" => msg}}} when ret != 0 ->
        {:error, "provider API error #{ret}: #{msg}"}

      {:ok, %{status: status, body: body}} ->
        {:error, "provider HTTP #{status}: #{inspect(body)}"}

      # The request may have reached the provider. The stable class keeps
      # that unknown outcome in model context after repair.
      {:error, %Req.TransportError{reason: :timeout} = reason} ->
        {:error, %{"error_class" => "provider_timeout", "message" => inspect(reason)}}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def default_base("", fallback), do: fallback
  def default_base(base, _fallback), do: String.trim_trailing(base, "/")

  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, ""), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  def maybe_put_present(map, _key, nil), do: map
  def maybe_put_present(map, _key, ""), do: map
  def maybe_put_present(map, key, value), do: Map.put(map, key, value)

  def maybe_put_string(map, _key, nil), do: map
  def maybe_put_string(map, _key, ""), do: map
  def maybe_put_string(map, key, value), do: Map.put(map, key, value)

  # ---- helpers ----

  def ensure_slash(url) do
    url = to_string(url)
    if String.ends_with?(url, "/"), do: url, else: url <> "/"
  end

  def int_or_zero(value) when is_integer(value), do: value
  def int_or_zero(_value), do: 0

  def random_id do
    <<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>> =
      :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> Enum.map(&Base.encode16(&1, case: :lower))
    |> Enum.join("-")
  end

  def str(value), do: value |> to_string_safe() |> String.trim()

  def to_string_safe(nil), do: ""
  def to_string_safe(value) when is_binary(value), do: value
  def to_string_safe(value), do: to_string(value)

  def int_or(value, _default) when is_integer(value), do: value

  def int_or(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end

  def int_or(_value, default), do: default

  def presence(""), do: nil
  def presence(value), do: value

  def put_present(map, _key, nil), do: map
  def put_present(map, _key, ""), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  @spec truncate_utf8(String.t(), non_neg_integer(), String.t()) :: String.t()
  def truncate_utf8(value, max_bytes, marker \\ "… [truncated]")
      when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 and is_binary(marker) do
    if byte_size(value) <= max_bytes do
      value
    else
      marker = utf8_prefix(marker, max_bytes)
      prefix = utf8_prefix(value, max(max_bytes - byte_size(marker), 0))
      prefix <> marker
    end
  end

  def control_error(reason) when is_binary(reason), do: reason
  def control_error({:bad_request, message}) when is_binary(message), do: message
  def control_error(reason), do: inspect(reason)

  defp utf8_prefix(value, max_bytes) do
    value
    |> binary_part(0, min(byte_size(value), max_bytes))
    |> valid_utf8_prefix()
  end

  defp valid_utf8_prefix(value) do
    if String.valid?(value),
      do: value,
      else: value |> binary_part(0, byte_size(value) - 1) |> valid_utf8_prefix()
  end
end
