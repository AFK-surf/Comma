defmodule SalixAgent.SubscriptionImport do
  @moduledoc "One-time import of the local encrypted Go vault into Salix."
  alias SalixAgent.SubscriptionStore, as: Store

  # Source files are preserved. The caller stops the old writer before copying
  # the directory. Re-running accepts only an identical record, never overwrites.
  def run(directory, tenant, key) do
    prefix = Base.url_encode64(tenant, padding: false)

    with {:ok, files} <- File.ls(Path.join(directory, prefix)) do
      files
      |> Enum.filter(&String.ends_with?(&1, ".json.enc"))
      |> Enum.reduce_while({:ok, 0}, fn file, {:ok, n} ->
        with {:ok, id} <-
               Base.url_decode64(String.replace_suffix(file, ".json.enc", ""), padding: false),
             {:ok, bytes} <- File.read(Path.join([directory, prefix, file])),
             {:ok, value} <- decode(bytes, key, tenant, id),
             :ok <- import_record(tenant, id, value) do
          {:cont, {:ok, n + 1}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp decode(<<nonce::binary-size(12), rest::binary>>, key, tenant, id)
       when byte_size(rest) >= 16 do
    size = byte_size(rest) - 16
    <<body::binary-size(^size), tag::binary-size(16)>> = rest

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           nonce,
           body,
           tenant <> "\0" <> id,
           tag,
           false
         ) do
      plain when is_binary(plain) -> Jason.decode(plain)
      _ -> {:error, :invalid_source_ciphertext}
    end
  end

  defp decode(_, _, _, _), do: {:error, :invalid_source_ciphertext}

  defp import_record(tenant, id, old) do
    metadata = Map.delete(old["metadata"], "salix_revision")

    with {:ok, ciphertext} <- Store.seal(tenant, id, metadata) do
      record = %{
        "id" => id,
        "credential_kind" => "subscription_oauth",
        "provider" => old["provider"],
        "email" => metadata["email"],
        "credentials" => ciphertext,
        "disabled" => old["disabled"] || false,
        "status" => "active"
      }

      case Store.get(tenant, id) do
        {:error, :not_found} ->
          case Store.create(tenant, record) do
            {:ok, _} -> :ok
            error -> error
          end

        {:ok, existing} ->
          with {:ok, ^metadata} <- Store.open(tenant, id, existing["credentials"]),
               true <-
                 existing["provider"] == record["provider"] and
                   existing["disabled"] == record["disabled"] do
            :ok
          else
            _ -> {:error, :divergent_import}
          end

        error ->
          error
      end
    end
  end
end
