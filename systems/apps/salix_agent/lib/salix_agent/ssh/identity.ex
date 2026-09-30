defmodule SalixAgent.SSH.Identity do
  @moduledoc """
  The Group's SSH client key.

  Every Agent in a Group authenticates to remote hosts with one Ed25519 key.
  It is generated on first use and stored unencrypted, as a PKCS#8 PEM, at
  `SalixStore.Keys.ctl_group_ssh_identity/1`. The first write is create-once
  (`if_none_match: "*"`): concurrent first callers converge on the one key
  that landed. There is no rotation. Group deletion removes the object.

  The private key never leaves this node's memory through a tool: callers get
  the public key line and fingerprint for display, and `private_key` only for
  `SalixAgent.SSH.KeyCallback`.
  """

  alias SalixStore.{Keys, S3}

  @ed25519 {1, 3, 101, 112}

  @type t :: %{
          private_key: tuple(),
          public_key: tuple(),
          public_key_line: String.t(),
          fingerprint: String.t()
        }

  @doc "Load the Group's key, creating it on first use."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, term()}
  def fetch(group_id) when is_binary(group_id) and group_id != "" do
    key = Keys.ctl_group_ssh_identity(group_id)

    case S3.get(key) do
      {:ok, %{body: pem}} -> decode(pem, group_id)
      {:error, :not_found} -> create(key, group_id)
      {:error, reason} -> {:error, {:identity_unavailable, reason}}
    end
  end

  def fetch(_group_id), do: {:error, :group_required}

  defp create(key, group_id) do
    pem = generate_pem()

    case S3.put(key, pem, if_none_match: "*", content_type: "application/x-pem-file") do
      {:ok, _} -> decode(pem, group_id)
      # Another caller created it first, or our own write may have landed:
      # the stored object is the key either way.
      {:error, :precondition_failed} -> reread(key, group_id)
      {:error, {:ambiguous, _}} -> reread(key, group_id)
      {:error, reason} -> {:error, {:identity_unavailable, reason}}
    end
  end

  defp reread(key, group_id) do
    case S3.get(key) do
      {:ok, %{body: pem}} -> decode(pem, group_id)
      {:error, reason} -> {:error, {:identity_unavailable, reason}}
    end
  end

  defp generate_pem do
    private = :public_key.generate_key({:namedCurve, :ed25519})
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, private)])
  end

  defp decode(pem, group_id) do
    with [entry] <- :public_key.pem_decode(pem),
         {:ECPrivateKey, _version, private, {:namedCurve, @ed25519} = curve, _, _} <-
           :public_key.pem_entry_decode(entry) do
      {public, _} = :crypto.generate_key(:eddsa, :ed25519, private)
      public_key = {{:ECPoint, public}, curve}

      {:ok,
       %{
         # Retain the public component that PKCS#8 decoding leaves unset.
         private_key: {:ECPrivateKey, :ecPrivkeyVer1, private, curve, public, :asn1_NOVALUE},
         public_key: public_key,
         public_key_line: public_key_line(public_key, group_id),
         fingerprint: fingerprint(public_key)
       }}
    else
      _ -> {:error, :invalid_identity}
    end
  rescue
    _ -> {:error, :invalid_identity}
  end

  @doc "An OpenSSH `authorized_keys` line for a public key."
  @spec public_key_line(tuple(), String.t()) :: String.t()
  def public_key_line(public_key, group_id) do
    [{public_key, [comment: String.to_charlist("salix-group-" <> group_id)]}]
    |> :ssh_file.encode(:openssh_key)
    |> String.trim()
  end

  @doc "The OpenSSH `SHA256:` fingerprint of a public key."
  @spec fingerprint(tuple()) :: String.t()
  def fingerprint(public_key), do: to_string(:ssh.hostkey_fingerprint(:sha256, public_key))
end
