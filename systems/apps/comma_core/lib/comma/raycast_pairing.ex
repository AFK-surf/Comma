defmodule Comma.RaycastPairing do
  @moduledoc """
  The desktop app's full Auth Session delegates one short-lived grant to the
  Raycast extension (`Comma.SessionPairing`).

  The grant travels in a `raycast://` link that any app on the computer can
  open or read. The extension therefore starts the pairing: it keeps a random
  verifier and sends only its SHA-256 challenge. The grant stores the
  challenge, and the exchange needs the verifier. A grant given to another
  extension install, or read by another app, cannot issue a session.
  """
  alias Comma.SessionPairing

  @purpose "raycast_pairing"
  # An unpadded base64url SHA-256, and the verifier it is the digest of.
  @challenge ~r/\A[A-Za-z0-9_-]{43}\z/
  @verifier ~r/\A[A-Za-z0-9._~-]{43,128}\z/

  def create(user, session, challenge) when is_binary(challenge) do
    if Regex.match?(@challenge, challenge),
      do: SessionPairing.create(@purpose, user, session, %{"challenge" => challenge}),
      else: {:error, :invalid_challenge}
  end

  def create(_user, _session, _challenge), do: {:error, :invalid_challenge}

  def exchange(attrs) when is_map(attrs) do
    case SessionPairing.exchange(@purpose, attrs, &session_options(&1, attrs)) do
      {:error, :invalid_pairing} -> {:error, :invalid_raycast_pairing}
      result -> result
    end
  end

  def exchange(_attrs), do: {:error, :invalid_raycast_pairing}

  defp session_options(grant, attrs) do
    if verifier_matches?(attrs["verifier"], grant["challenge"]) do
      {:ok,
       [
         auth_method: "raycast_pairing",
         client_kind: "raycast",
         client_platform: client_platform(attrs["client_platform"]),
         device_label: "Comma for Raycast"
       ]}
    else
      :error
    end
  end

  defp verifier_matches?(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    digest = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    Regex.match?(@verifier, verifier) and byte_size(digest) == byte_size(challenge) and
      :crypto.hash_equals(digest, challenge)
  end

  defp verifier_matches?(_verifier, _challenge), do: false

  defp client_platform(platform) when platform in ["macos", "windows"], do: platform
  defp client_platform(_platform), do: "unknown"
end
