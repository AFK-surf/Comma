defmodule SalixIM.Provider.Feishu.ResourceRef do
  @moduledoc false

  @prefix "fr2."
  @mac_domain "salix-im/feishu/resource-ref/v2"
  @separator <<0>>
  @max_ref_bytes 4_096
  @resource_types ~w(file image)

  @type locator :: %{String.t() => String.t()}

  @spec encode(binary(), binary(), term(), term(), term()) ::
          {:ok, String.t()} | {:error, String.t()}
  def encode(scope, signing_key, message_id, file_key, resource_type) do
    with :ok <- validate_signing_context(scope, signing_key),
         {:ok, locator} <- validate_locator(message_id, file_key, resource_type) do
      payload =
        Enum.join(
          [locator["message_id"], locator["file_key"], locator["resource_type"]],
          @separator
        )

      encoded_payload = Base.url_encode64(payload, padding: false)
      encoded_mac = payload |> mac(scope, signing_key) |> Base.url_encode64(padding: false)

      {:ok, @prefix <> encoded_payload <> "." <> encoded_mac}
    end
  end

  @spec decode(term(), binary(), binary()) :: {:ok, locator()} | {:error, String.t()}
  def decode(resource_ref, scope, signing_key) when is_binary(resource_ref) do
    resource_ref = String.trim(resource_ref)

    with :ok <- validate_signing_context(scope, signing_key),
         true <- byte_size(resource_ref) <= @max_ref_bytes,
         true <- String.starts_with?(resource_ref, @prefix),
         [encoded_payload, encoded_mac] <-
           resource_ref
           |> String.replace_prefix(@prefix, "")
           |> String.split(".", parts: 2),
         {:ok, payload} <- Base.url_decode64(encoded_payload, padding: false),
         {:ok, supplied_mac} <- Base.url_decode64(encoded_mac, padding: false),
         true <- secure_compare(supplied_mac, mac(payload, scope, signing_key)),
         [message_id, file_key, resource_type] <-
           :binary.split(payload, @separator, [:global]),
         {:ok, locator} <- validate_locator(message_id, file_key, resource_type),
         {:ok, ^resource_ref} <-
           encode(
             scope,
             signing_key,
             locator["message_id"],
             locator["file_key"],
             locator["resource_type"]
           ) do
      {:ok, locator}
    else
      _ -> {:error, invalid_ref_error()}
    end
  end

  def decode(_resource_ref, _scope, _signing_key), do: {:error, invalid_ref_error()}

  defp validate_locator(message_id, file_key, resource_type) do
    message_id = clean(message_id)
    file_key = clean(file_key)
    resource_type = clean(resource_type)

    cond do
      message_id == "" ->
        {:error, invalid_ref_error()}

      file_key == "" ->
        {:error, invalid_ref_error()}

      resource_type not in @resource_types ->
        {:error, invalid_ref_error()}

      contains_separator?(message_id) ->
        {:error, invalid_ref_error()}

      contains_separator?(file_key) ->
        {:error, invalid_ref_error()}

      true ->
        {:ok,
         %{
           "message_id" => message_id,
           "file_key" => file_key,
           "resource_type" => resource_type
         }}
    end
  end

  defp validate_signing_context(scope, signing_key)
       when is_binary(scope) and scope != "" and is_binary(signing_key) and
              byte_size(signing_key) >= 16,
       do: :ok

  defp validate_signing_context(_scope, _signing_key), do: {:error, invalid_ref_error()}

  defp mac(payload, scope, signing_key) do
    input = [@mac_domain, <<byte_size(scope)::unsigned-32>>, scope, payload]
    :crypto.mac(:hmac, :sha256, signing_key, input)
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right),
    do: byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_left, _right), do: false

  defp contains_separator?(value), do: :binary.match(value, @separator) != :nomatch

  defp clean(nil), do: ""
  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(value), do: value |> to_string() |> String.trim()

  defp invalid_ref_error do
    "invalid Feishu resource_ref; copy the exact resource_ref returned by the latest Feishu history, thread, message, or file-list call and retry"
  end
end
