defmodule SalixAgent.DeviceSecrets do
  @moduledoc """
  The Group's secrets for devices on the user's local network, such as a
  Xiaomi lamp's miIO token or an ONVIF camera's password. Tools use a secret
  by name (`token_ref`, `secret_ref`); its value never returns to the model or
  to a client.

  One JSON record per Group at `SalixStore.Keys.ctl_group_device_secrets/1`,
  changed only by compare-and-swap (`SalixStore.CasRecord`). Each entry keeps
  its kind, name and non-secret metadata in clear and its value sealed with
  AES-256-GCM under the deployment credential root
  (`SalixStore.Crypto.derived_key/1`, purpose `device-secret-v1`). The AAD
  binds the ciphertext to its Group, name and kind, so a value copied into
  another entry or Group does not decrypt. The root protects a stolen object
  store; application compromise is outside this boundary.

  Saving a name that exists replaces its value and metadata. `last_used_at`
  is written at most once an hour per entry, after a successful use, and a
  failed write does not fail the use. Group deletion removes the record
  (`delete_group_data/1`).
  """

  alias SalixStore.{CasRecord, Crypto, Keys, S3}

  @purpose "device-secret-v1"
  @max_secrets 128
  @max_value_bytes 512
  @touch_interval_s 3_600

  # Each kind declares the exact shape of its values.
  @formats %{
    "miio_token" => %{value: ~S"\A[0-9a-fA-F]{32}\z"},
    # Printable ASCII without spaces.
    "onvif_password" => %{value: ~S"\A[\x21-\x7E]{4,64}\z"}
  }
  @kinds @formats |> Map.keys() |> Enum.sort()

  @doc "Kinds a secret can have."
  def kinds, do: @kinds

  @doc "Most secrets one Group keeps."
  def max_secrets, do: @max_secrets

  @doc """
  Save `attrs` (`"kind"`, `"name"`, `"value"`, optional `"host"` and
  `"model"`). Returns `{:ok, metadata, :created | :replaced}`; the metadata
  never contains the value.
  """
  def save(group_id, attrs) when is_binary(group_id) and is_map(attrs) do
    with {:ok, kind} <- kind(attrs["kind"]),
         {:ok, name} <- name(attrs["name"]),
         {:ok, value} <- value(kind, attrs["value"]),
         {:ok, host} <- optional_text(attrs["host"], :invalid_host, 253),
         {:ok, model} <- optional_text(attrs["model"], :invalid_model, 128),
         {:ok, sealed} <- seal(group_id, name, kind, value) do
      now = now()

      result =
        CasRecord.update(Keys.ctl_group_device_secrets(group_id), fn current ->
          secrets = secrets(current)
          previous = Map.get(secrets, name)
          # The last attempt's answer wins; CasRecord retries this function.
          Process.put({__MODULE__, :replaced}, previous != nil)

          if previous == nil and map_size(secrets) >= @max_secrets do
            {:error, :too_many_secrets}
          else
            entry =
              %{
                "name" => name,
                "kind" => kind,
                "host" => host,
                "model" => model,
                "ciphertext" => sealed,
                "created_at" => (previous && previous["created_at"]) || now,
                "updated_at" => now,
                "last_used_at" => nil
              }

            %{"secrets" => Map.put(secrets, name, entry)}
          end
        end)

      case result do
        {:ok, %{"secrets" => %{^name => entry}}} ->
          replaced? = Process.delete({__MODULE__, :replaced})
          {:ok, metadata(entry), if(replaced?, do: :replaced, else: :created)}

        {:error, :too_many_secrets} = error ->
          Process.delete({__MODULE__, :replaced})
          error

        {:error, reason} ->
          Process.delete({__MODULE__, :replaced})
          {:error, {:device_secrets_unavailable, reason}}
      end
    end
  end

  @doc "Metadata of every secret, sorted by name. No values."
  def list(group_id) when is_binary(group_id) do
    with {:ok, record} <- read(group_id) do
      {:ok,
       record |> secrets() |> Map.values() |> Enum.map(&metadata/1) |> Enum.sort_by(& &1["name"])}
    end
  end

  @doc "Delete a secret by name. Returns its metadata, or nil when there was none."
  def delete(group_id, name) when is_binary(group_id) do
    with {:ok, name} <- name(name),
         {:ok, current} <- read(group_id) do
      case Map.get(secrets(current), name) do
        nil ->
          {:ok, nil}

        entry ->
          result =
            CasRecord.update(
              Keys.ctl_group_device_secrets(group_id),
              fn
                nil -> {:unchanged, %{"secrets" => %{}}}
                record -> %{"secrets" => Map.delete(secrets(record), name)}
              end,
              create: false
            )

          case result do
            {:ok, _} -> {:ok, metadata(entry)}
            {:error, :not_found} -> {:ok, nil}
            {:error, reason} -> {:error, {:device_secrets_unavailable, reason}}
          end
      end
    end
  end

  @doc """
  The value of the secret `name` of `kind`, for a codec at dispatch time.
  Returns `{:ok, value, metadata}`, `{:error, :not_found}`,
  `{:error, {:wrong_kind, kind}}` or `{:error, reason}`.
  """
  def resolve(group_id, name, kind) when is_binary(group_id) do
    with {:ok, name} <- name(name),
         {:ok, record} <- read(group_id) do
      case Map.get(secrets(record), name) do
        nil ->
          {:error, :not_found}

        %{"kind" => ^kind, "ciphertext" => sealed} = entry ->
          case unseal(group_id, name, kind, sealed) do
            {:ok, value} -> {:ok, value, metadata(entry)}
            {:error, _} = error -> error
          end

        %{"kind" => other} ->
          {:error, {:wrong_kind, other}}
      end
    end
  end

  @doc "Record a successful use, at most once per hour per secret. Never fails."
  def touch(group_id, %{"name" => name, "last_used_at" => last_used_at}) do
    if stale?(last_used_at) do
      now = now()

      _ =
        CasRecord.update(
          Keys.ctl_group_device_secrets(group_id),
          fn
            nil ->
              {:unchanged, nil}

            record ->
              case Map.get(secrets(record), name) do
                nil ->
                  {:unchanged, record}

                entry ->
                  %{
                    "secrets" =>
                      Map.put(secrets(record), name, Map.put(entry, "last_used_at", now))
                  }
              end
          end,
          create: false
        )
    end

    :ok
  rescue
    _ -> :ok
  end

  def touch(_group_id, _metadata), do: :ok

  @doc "Remove the Group's secrets. Part of Group deletion."
  def delete_group_data(group_id) when is_binary(group_id) and group_id != "" do
    case S3.delete(Keys.ctl_group_device_secrets(group_id)) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:device_secrets_delete_failed, reason}}
    end
  end

  # ---- helpers ----------------------------------------------------------------------

  defp read(group_id) do
    case CasRecord.get(Keys.ctl_group_device_secrets(group_id)) do
      {:ok, record} -> {:ok, record}
      {:error, :not_found} -> {:ok, %{"secrets" => %{}}}
      {:error, reason} -> {:error, {:device_secrets_unavailable, reason}}
    end
  end

  defp secrets(%{"secrets" => secrets}) when is_map(secrets), do: secrets
  defp secrets(_record), do: %{}

  defp metadata(entry), do: Map.drop(entry, ["ciphertext"])

  defp kind(kind) when kind in @kinds, do: {:ok, kind}
  defp kind(_kind), do: {:error, :invalid_kind}

  defp name(name) when is_binary(name) do
    name = String.trim(name)

    if name != "" and String.length(name) <= 64 and String.valid?(name) and
         not String.match?(name, ~r/[\x00-\x1f\x7f\/]/),
       do: {:ok, name},
       else: {:error, :invalid_name}
  end

  defp name(_name), do: {:error, :invalid_name}

  # Errors never include the value.
  defp value(kind, value) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) <= @max_value_bytes and value?(kind, value),
      do: {:ok, value},
      else: {:error, :invalid_value}
  end

  defp value(_kind, _value), do: {:error, :invalid_value}

  defp value?(kind, value),
    do: String.match?(value, Regex.compile!(Map.fetch!(@formats, kind).value))

  defp optional_text(nil, _error, _max), do: {:ok, nil}

  defp optional_text(text, error, max) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:ok, nil}
      String.length(text) <= max and not String.match?(text, ~r/[\x00-\x1f\x7f]/) -> {:ok, text}
      true -> {:error, error}
    end
  end

  defp optional_text(_text, error, _max), do: {:error, error}

  defp stale?(nil), do: true

  defp stale?(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _} -> DateTime.diff(SystemsClock.utc_now(), at) >= @touch_interval_s
      _ -> true
    end
  end

  defp stale?(_at), do: true

  defp aad(group_id, name, kind), do: Jason.encode!([@purpose, group_id, name, kind])

  defp seal(group_id, name, kind, value) do
    with {:ok, key} <- Crypto.derived_key(@purpose) do
      iv = SystemsRuntime.Proc.random_bytes(12)

      {cipher, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          iv,
          value,
          aad(group_id, name, kind),
          true
        )

      {:ok, "v1." <> Base.url_encode64(iv <> tag <> cipher, padding: false)}
    end
  end

  defp unseal(group_id, name, kind, "v1." <> encoded) do
    with {:ok, key} <- Crypto.derived_key(@purpose),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), cipher::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         value when is_binary(value) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             cipher,
             aad(group_id, name, kind),
             tag,
             false
           ) do
      {:ok, value}
    else
      {:error, :credential_sealer_unavailable} = error -> error
      _ -> {:error, :undecryptable}
    end
  end

  defp unseal(_group_id, _name, _kind, _sealed), do: {:error, :undecryptable}

  defp now, do: SystemsClock.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
