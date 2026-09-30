defmodule SalixVoice.Settings do
  @moduledoc """
  Platform voice settings (docs/messaging-voice.md).

  One JSON object at `ctl/system/voice.json`, managed from the Salix dashboard.
  There are no environment variables or `config.json` entries for voice.
  Writes are compare-and-swap on the object's etag. Secrets are write-only:
  `redacted/0` and the result of `update/1` replace each stored secret with
  `"<field>_configured" => true`. A blank or absent secret in an update keeps
  the stored value; `"clear_secrets" => [field]` removes one.
  """

  alias SalixStore.{Keys, S3}

  @default_gpt_live_url "wss://api.openai.com/v1/live/sessions"

  @defaults %{
    "enabled" => false,
    "gpt_live_model" => "gpt-live-1",
    "gpt_live_url" => @default_gpt_live_url,
    "gpt_live_voice" => nil,
    "openai_api_key" => nil,
    "twilio_account_sid" => nil,
    "twilio_auth_token" => nil,
    "twilio_verify_service_sid" => nil,
    "twilio_numbers" => [],
    "public_base_url" => nil,
    "max_call_seconds" => 1800,
    "max_calls_per_node" => 50,
    "pin_max_failures" => 5,
    "pin_lockout_seconds" => 900
  }

  @secret_fields ~w(openai_api_key twilio_auth_token)
  @string_fields ~w(gpt_live_model gpt_live_voice twilio_account_sid twilio_verify_service_sid)
  @integer_bounds %{
    "max_call_seconds" => {30, 14_400},
    "max_calls_per_node" => {1, 10_000},
    "pin_max_failures" => {1, 100},
    "pin_lockout_seconds" => {1, 604_800}
  }
  @fields Map.keys(@defaults)
  @cas_attempts 3

  @doc "The documented default GPT-Live WebSocket URL."
  def default_gpt_live_url, do: @default_gpt_live_url

  @doc "Field defaults, secrets included as `nil`."
  def defaults, do: @defaults

  @doc "Names of the write-only secret fields."
  def secret_fields, do: @secret_fields

  @doc """
  Effective settings with defaults applied, secrets included. For call
  admission and carrier code only; never return this map to a UI.
  """
  @spec get() :: {:ok, map()} | {:error, term()}
  def get do
    with {:ok, stored, _etag} <- read() do
      {:ok, Map.merge(@defaults, stored)}
    end
  end

  @doc "Effective settings with secrets replaced by `<field>_configured` flags."
  @spec redacted() :: {:ok, map()} | {:error, term()}
  def redacted do
    with {:ok, settings} <- get(), do: {:ok, redact(settings)}
  end

  @doc "Redact an effective settings map for a UI or API response."
  @spec redact(map()) :: map()
  def redact(settings) when is_map(settings) do
    Enum.reduce(@secret_fields, settings, fn field, acc ->
      acc
      |> Map.delete(field)
      |> Map.put(field <> "_configured", present?(settings[field]))
    end)
  end

  @doc """
  Merge `attrs` into the stored settings with compare-and-swap. Unknown fields
  are ignored. Returns the redacted effective settings.
  """
  @spec update(map()) :: {:ok, map()} | {:error, term()}
  def update(attrs) when is_map(attrs), do: update(attrs, @cas_attempts)
  def update(_attrs), do: {:error, {:bad_request, "voice settings must be a JSON object"}}

  defp update(_attrs, 0), do: {:error, :conflict}

  defp update(attrs, attempts) do
    with {:ok, changes, clears} <- validate(attrs),
         {:ok, stored, etag} <- read() do
      next =
        stored
        |> Map.merge(changes)
        |> Map.drop(clears)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      body = Jason.encode!(next)

      put_result =
        if etag,
          do: S3.put(Keys.ctl_system_voice(), body, if_match: etag),
          else: S3.put(Keys.ctl_system_voice(), body, if_none_match: "*")

      case put_result do
        {:ok, _} -> {:ok, redact(Map.merge(@defaults, next))}
        {:error, :precondition_failed} -> update(attrs, attempts - 1)
        {:error, _} = error -> error
      end
    end
  end

  defp read do
    case S3.get(Keys.ctl_system_voice()) do
      {:ok, %{body: body} = object} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, Map.take(map, @fields), object[:etag]}
          _ -> {:error, :voice_settings_invalid}
        end

      {:error, :not_found} ->
        {:ok, %{}, nil}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def validate(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with {:ok, clears} <- validate_clears(attrs["clear_secrets"]) do
      attrs
      |> Map.take(@fields)
      |> Enum.reduce_while({:ok, %{}}, fn {field, value}, {:ok, acc} ->
        case validate_field(field, value) do
          :skip -> {:cont, {:ok, acc}}
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, field, normalized)}}
          {:error, message} -> {:halt, {:error, {:bad_request, message}}}
        end
      end)
      |> case do
        {:ok, changes} -> {:ok, changes, clears}
        error -> error
      end
    end
  end

  defp validate_clears(nil), do: {:ok, []}

  defp validate_clears(list) when is_list(list) do
    if Enum.all?(list, &(&1 in @secret_fields)),
      do: {:ok, list},
      else:
        {:error, {:bad_request, "clear_secrets may only name #{Enum.join(@secret_fields, ", ")}"}}
  end

  defp validate_clears(_), do: {:error, {:bad_request, "clear_secrets must be a list"}}

  defp validate_field("enabled", value) when is_boolean(value), do: {:ok, value}
  defp validate_field("enabled", _), do: {:error, "enabled must be a boolean"}

  defp validate_field(field, value) when field in @secret_fields do
    case blank(value) do
      nil when is_nil(value) or is_binary(value) -> :skip
      nil -> {:error, "#{field} must be a string"}
      secret -> {:ok, secret}
    end
  end

  defp validate_field(field, value) when field in @string_fields do
    cond do
      is_nil(value) -> {:ok, nil}
      is_binary(value) and byte_size(value) <= 256 -> {:ok, blank(value)}
      true -> {:error, "#{field} must be a string of at most 256 bytes"}
    end
  end

  # The OpenAI key travels in the upgrade request, so the model URL must use
  # TLS. Plain `ws` is accepted only for a loopback host (a local fake).
  defp validate_field("gpt_live_url", value) do
    case blank(value) do
      nil ->
        {:ok, nil}

      url ->
        with {:ok, url} <- url_field("gpt_live_url", url, ["wss", "ws"]) do
          case URI.parse(url) do
            %URI{scheme: "ws", host: host} ->
              if loopback_host?(host),
                do: {:ok, url},
                else: {:error, "gpt_live_url must use wss (ws only for a loopback host)"}

            _wss ->
              {:ok, url}
          end
        end
    end
  end

  defp validate_field("public_base_url", value) do
    case blank(value) do
      nil -> {:ok, nil}
      url -> url_field("public_base_url", String.trim_trailing(url, "/"), ["https", "http"])
    end
  end

  defp validate_field("twilio_numbers", value) when is_list(value) do
    numbers = Enum.map(value, &(is_binary(&1) && String.trim(&1)))

    cond do
      length(numbers) > 100 -> {:error, "twilio_numbers may list at most 100 numbers"}
      Enum.all?(numbers, &e164?/1) -> {:ok, Enum.uniq(numbers)}
      true -> {:error, "twilio_numbers must be E.164 numbers such as +15551234567"}
    end
  end

  defp validate_field("twilio_numbers", nil), do: {:ok, nil}
  defp validate_field("twilio_numbers", _), do: {:error, "twilio_numbers must be a list"}

  defp validate_field(field, value) when is_map_key(@integer_bounds, field) do
    {min, max} = Map.fetch!(@integer_bounds, field)

    cond do
      is_nil(value) -> {:ok, nil}
      is_integer(value) and value >= min and value <= max -> {:ok, value}
      true -> {:error, "#{field} must be an integer from #{min} to #{max}"}
    end
  end

  defp url_field(field, url, schemes) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when is_binary(host) and host != "" ->
        if scheme in schemes,
          do: {:ok, url},
          else: {:error, "#{field} must use #{Enum.join(schemes, " or ")}"}

      _ ->
        {:error, "#{field} must be an absolute URL"}
    end
  end

  defp loopback_host?(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.downcase()

    host == "localhost" or
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, {127, _, _, _}} -> true
        {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
        _ -> false
      end
  end

  @doc "True for an E.164 number: `+` and 8 to 15 digits, no leading zero."
  def e164?(value) when is_binary(value), do: Regex.match?(~r/^\+[1-9][0-9]{7,14}$/, value)
  def e164?(_), do: false

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank(_), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
