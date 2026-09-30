defmodule Comma.Auth.GoogleClaims do
  @moduledoc "Typed, conservative view of claims from a cryptographically verified Google ID token."

  alias Comma.Accounts.Email
  alias Comma.Auth.HostedDomain

  @canonical_issuer "https://accounts.google.com"

  @enforce_keys [:issuer, :subject]
  defstruct [
    :issuer,
    :subject,
    :email,
    :email_verified,
    :hosted_domain,
    :name
  ]

  @type t :: %__MODULE__{
          issuer: String.t(),
          subject: String.t(),
          email: String.t() | nil,
          email_verified: boolean() | :invalid,
          hosted_domain: String.t() | nil | :invalid,
          name: String.t() | nil
        }

  @spec from_verified(map()) :: {:ok, t()} | {:error, :invalid_google_identity}
  def from_verified(claims) when is_map(claims) do
    with {:ok, issuer} <- canonical_issuer(value(claims, "iss")),
         {:ok, subject} <- nonempty_string(value(claims, "sub"), 500) do
      {:ok,
       %__MODULE__{
         issuer: issuer,
         subject: subject,
         email: normalized_email(value(claims, "email")),
         email_verified: verified_claim(value(claims, "email_verified")),
         hosted_domain: hosted_domain(value(claims, "hd")),
         name: optional_string(value(claims, "name"), 200)
       }}
    else
      _error -> {:error, :invalid_google_identity}
    end
  end

  def from_verified(_claims), do: {:error, :invalid_google_identity}

  @spec identity_attrs(t()) :: map()
  def identity_attrs(%__MODULE__{} = claims) do
    %{
      provider: "google",
      issuer: claims.issuer,
      subject: claims.subject,
      email_snapshot: claims.email,
      email_verified: claims.email_verified == true,
      hosted_domain: valid_hosted_domain(claims.hosted_domain),
      last_authenticated_at: DateTime.utc_now()
    }
  end

  @spec link_state(t(), String.t()) :: map()
  def link_state(%__MODULE__{} = claims, user_id)
      when is_binary(user_id) and is_binary(claims.email) do
    %{
      "user_id" => user_id,
      "issuer" => claims.issuer,
      "subject" => claims.subject,
      "email" => claims.email,
      "email_verified" => claims.email_verified == true,
      "hosted_domain" => valid_hosted_domain(claims.hosted_domain)
    }
  end

  @spec from_link_state(map()) :: {:ok, t()} | {:error, :invalid_google_identity}
  def from_link_state(state) when is_map(state) do
    from_verified(%{
      "iss" => value(state, "issuer"),
      "sub" => value(state, "subject"),
      "email" => value(state, "email"),
      "email_verified" => value(state, "email_verified"),
      "hd" => value(state, "hosted_domain")
    })
  end

  def from_link_state(_state), do: {:error, :invalid_google_identity}

  defp canonical_issuer(issuer) when issuer in ["accounts.google.com", @canonical_issuer],
    do: {:ok, @canonical_issuer}

  defp canonical_issuer(_issuer), do: {:error, :invalid_issuer}

  defp normalized_email(email) do
    case Email.normalize(email) do
      {:ok, normalized} -> normalized
      {:error, :invalid_email} -> nil
    end
  end

  defp verified_claim(value) when is_boolean(value), do: value
  defp verified_claim(_value), do: :invalid

  defp hosted_domain(nil), do: nil

  defp hosted_domain(value) when is_binary(value) do
    case HostedDomain.normalize(value) do
      {:ok, normalized} -> normalized
      {:error, :invalid_hosted_domain} -> :invalid
    end
  end

  defp hosted_domain(_value), do: :invalid

  defp valid_hosted_domain(value) when is_binary(value), do: value
  defp valid_hosted_domain(_value), do: nil

  defp nonempty_string(value, max_bytes) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= max_bytes,
      do: {:ok, value},
      else: {:error, :invalid_string}
  end

  defp nonempty_string(_value, _max_bytes), do: {:error, :invalid_string}

  defp optional_string(value, max_length) when is_binary(value) do
    value = String.trim(value)
    if value != "" and String.length(value) <= max_length, do: value
  end

  defp optional_string(_value, _max_length), do: nil

  defp value(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
end
