defmodule Comma.Accounts.Email do
  @moduledoc "Exact Comma account-email normalization shared by persistence boundaries."

  @max_bytes 320
  @format ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u
  @max_recipient_bytes 254
  @max_local_bytes 64
  @max_domain_bytes 255
  @max_domain_label_bytes 63
  @local_atom_format ~r/^[a-z0-9!#$%&'*+\/=^_`{|}~-]+$/
  @domain_label_format ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/

  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_email}
  def normalize(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    if normalized != "" and byte_size(normalized) <= @max_bytes and
         Regex.match?(@format, normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_email}
    end
  end

  def normalize(_email), do: {:error, :invalid_email}

  @doc "Normalizes an OTP recipient and rejects addresses Postmark cannot accept."
  @spec normalize_recipient(term()) :: {:ok, String.t()} | {:error, :invalid_email}
  def normalize_recipient(email) do
    with {:ok, normalized} <- normalize(email),
         false <- Comma.GuestMode.guest_email?(normalized),
         true <- byte_size(normalized) <= @max_recipient_bytes,
         [local_part, domain] <- String.split(normalized, "@", parts: 2),
         true <- valid_local_part?(local_part),
         true <- valid_domain?(domain) do
      {:ok, normalized}
    else
      _other -> {:error, :invalid_email}
    end
  end

  defp valid_local_part?(local_part) do
    byte_size(local_part) in 1..@max_local_bytes and
      local_part
      |> String.split(".", trim: false)
      |> Enum.all?(&Regex.match?(@local_atom_format, &1))
  end

  defp valid_domain?(domain) do
    labels = String.split(domain, ".", trim: false)

    byte_size(domain) in 1..@max_domain_bytes and length(labels) >= 2 and
      Enum.all?(labels, fn label ->
        byte_size(label) in 1..@max_domain_label_bytes and
          Regex.match?(@domain_label_format, label)
      end)
  end
end
