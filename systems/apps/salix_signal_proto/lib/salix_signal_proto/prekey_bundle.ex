defmodule SalixSignalProto.PreKeyBundle do
  @moduledoc """
  A pre-key bundle for one device of a peer (CRS-03 §9.6): what an initiator
  needs to start a session.

  `from_service_response/1` builds one bundle for each element of `devices`
  in the service's response to `GET /v2/keys/{service-id}/{device}`
  (CRS-03 §9.5). Keys are base64 with or without padding.
  """

  alias SalixSignalProto.Keys

  @enforce_keys [
    :registration_id,
    :device_id,
    :identity_key,
    :signed_pre_key_id,
    :signed_pre_key,
    :signed_pre_key_signature
  ]
  defstruct [
    :registration_id,
    :device_id,
    :identity_key,
    :one_time_pre_key_id,
    :one_time_pre_key,
    :signed_pre_key_id,
    :signed_pre_key,
    :signed_pre_key_signature,
    :kem_pre_key_id,
    :kem_pre_key,
    :kem_pre_key_signature
  ]

  @type t :: %__MODULE__{
          registration_id: non_neg_integer(),
          device_id: non_neg_integer(),
          identity_key: Keys.ec_public(),
          one_time_pre_key_id: non_neg_integer() | nil,
          one_time_pre_key: Keys.ec_public() | nil,
          signed_pre_key_id: non_neg_integer(),
          signed_pre_key: Keys.ec_public(),
          signed_pre_key_signature: binary(),
          kem_pre_key_id: non_neg_integer() | nil,
          kem_pre_key: Keys.kem_public() | nil,
          kem_pre_key_signature: binary() | nil
        }

  @doc """
  Parses a decoded JSON pre-key response. Returns `{:error, :malformed}` when
  a required field is missing, a key does not parse, or a device ID is outside
  1 to 127 (CRS-03 §8).
  """
  @spec from_service_response(map()) :: {:ok, [t()]} | {:error, :malformed}
  def from_service_response(%{"identityKey" => identity, "devices" => devices})
      when is_list(devices) do
    with {:ok, identity_key} <- ec_key(identity) do
      devices
      |> Enum.reduce_while({:ok, []}, fn device, {:ok, acc} ->
        case device(device, identity_key) do
          {:ok, bundle} -> {:cont, {:ok, [bundle | acc]}}
          :error -> {:halt, {:error, :malformed}}
        end
      end)
      |> case do
        {:ok, bundles} -> {:ok, Enum.reverse(bundles)}
        error -> error
      end
    else
      _ -> {:error, :malformed}
    end
  end

  def from_service_response(_response), do: {:error, :malformed}

  defp device(
         %{
           "deviceId" => device_id,
           "registrationId" => registration_id,
           "signedPreKey" => %{
             "keyId" => signed_id,
             "publicKey" => signed,
             "signature" => signed_sig
           }
         } = device,
         identity_key
       )
       when is_integer(device_id) and is_integer(registration_id) and is_integer(signed_id) do
    with true <- Keys.valid_device_id?(device_id),
         {:ok, signed_pre_key} <- ec_key(signed),
         {:ok, signed_signature} <- base64(signed_sig),
         {:ok, one_time} <- optional_one_time(Map.get(device, "preKey")),
         {:ok, kem} <- optional_kem(Map.get(device, "pqPreKey")) do
      {:ok,
       %__MODULE__{
         registration_id: registration_id,
         device_id: device_id,
         identity_key: identity_key,
         one_time_pre_key_id: one_time && elem(one_time, 0),
         one_time_pre_key: one_time && elem(one_time, 1),
         signed_pre_key_id: signed_id,
         signed_pre_key: signed_pre_key,
         signed_pre_key_signature: signed_signature,
         kem_pre_key_id: kem && elem(kem, 0),
         kem_pre_key: kem && elem(kem, 1),
         kem_pre_key_signature: kem && elem(kem, 2)
       }}
    else
      _ -> :error
    end
  end

  defp device(_device, _identity_key), do: :error

  # An empty publicKey string is read as absent (CRS-03 §9.1).
  defp optional_one_time(nil), do: {:ok, nil}
  defp optional_one_time(%{"publicKey" => ""}), do: {:ok, nil}

  defp optional_one_time(%{"keyId" => id, "publicKey" => public}) when is_integer(id) do
    with {:ok, key} <- ec_key(public), do: {:ok, {id, key}}
  end

  defp optional_one_time(_other), do: :error

  defp optional_kem(nil), do: {:ok, nil}
  defp optional_kem(%{"publicKey" => ""}), do: {:ok, nil}

  defp optional_kem(%{"keyId" => id, "publicKey" => public, "signature" => signature})
       when is_integer(id) do
    with {:ok, bytes} <- base64(public),
         {:ok, key} <- Keys.parse_kem_public(bytes),
         {:ok, signature} <- base64(signature) do
      {:ok, {id, key, signature}}
    else
      _ -> :error
    end
  end

  defp optional_kem(_other), do: :error

  defp ec_key(encoded) do
    with {:ok, bytes} <- base64(encoded),
         {:ok, key} <- Keys.parse_ec_public(bytes) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  defp base64(encoded) when is_binary(encoded) do
    case Base.decode64(encoded, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp base64(_encoded), do: :error

  @doc """
  Checks a bundle before a session starts (CRS-03 §9.6): the signed EC
  pre-key and the KEM pre-key must be signed by the identity key, and a KEM
  pre-key must be present.
  """
  @spec verify(t()) :: :ok | {:error, :missing_kem_pre_key | :invalid_signature}
  def verify(%__MODULE__{kem_pre_key: nil}), do: {:error, :missing_kem_pre_key}

  def verify(%__MODULE__{} = bundle) do
    signed_ok =
      Keys.verify_signature(
        bundle.identity_key,
        bundle.signed_pre_key,
        bundle.signed_pre_key_signature
      )

    kem_ok =
      Keys.verify_signature(bundle.identity_key, bundle.kem_pre_key, bundle.kem_pre_key_signature)

    if signed_ok and kem_ok, do: :ok, else: {:error, :invalid_signature}
  end
end
