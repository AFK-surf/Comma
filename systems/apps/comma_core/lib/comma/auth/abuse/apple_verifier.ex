defmodule Comma.Auth.Abuse.AppleVerifier do
  @moduledoc false
  @root_path Path.expand("../../../../priv/auth/apple-app-attest-root.pem", __DIR__)
  @external_resource @root_path
  [{:Certificate, root, :not_encrypted}] = @root_path |> File.read!() |> :public_key.pem_decode()
  @root root
  require Record

  Record.defrecordp(
    :cert,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :alg,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @nonce_oid {1, 2, 840, 113_635, 100, 8, 2}
  @p256_oid {1, 2, 840, 10045, 3, 1, 7}
  @ec_oid {1, 2, 840, 10045, 2, 1}

  def attest(encoded, key_id, proof_bytes, app_id, environment, options \\ []) do
    opts = %{
      root: Keyword.get(options, :root, @root),
      now: SystemsClock.utc_now(),
      app_id: app_id,
      environment: environment
    }

    try do
      %{"fmt" => "apple-appattest", "attStmt" => %{"x5c" => chain}, "authData" => raw_auth} =
        decode(encoded)

      true = length(chain) in 2..3
      chain = Enum.map(chain, &bytes/1)
      Enum.each(chain, fn cert -> true = byte_size(cert) <= 4096 end)
      [leaf | _] = chain
      root = opts.root
      true = valid_chain?(root, chain, opts.now)
      leaf_cert = :public_key.pkix_decode_cert(leaf, :otp)
      public_key = public_key(leaf_cert)
      auth = bytes(raw_auth)

      <<rp_id::binary-size(32), flags, 0::32, aaguid::binary-size(16), 32::16,
        credential_id::binary-size(32), _rest::binary>> = auth

      true = Bitwise.band(flags, 0x40) == 0x40
      true = rp_id == :crypto.hash(:sha256, opts.app_id)
      true = aaguid == aaguid(opts.environment)
      key_hash = Base.decode64!(key_id)
      true = byte_size(key_hash) == 32 and credential_id == key_hash
      true = key_hash == :crypto.hash(:sha256, public_key)
      expected_nonce = :crypto.hash(:sha256, auth <> :crypto.hash(:sha256, proof_bytes))

      [nonce_extension] =
        Enum.filter(
          tbs(cert(leaf_cert, :tbsCertificate), :extensions),
          &(extension(&1, :extnID) == @nonce_oid)
        )

      {:ok, {:Nonce, nonce}, <<>>} =
        :CommaAppAttestNonce.decode(:Nonce, extension(nonce_extension, :extnValue))

      true = nonce == expected_nonce
      {:ok, %{public_key: public_key, counter: 0, environment: opts.environment}}
    rescue
      _ -> {:error, :invalid_attestation}
    catch
      _, _ -> {:error, :invalid_attestation}
    end
  end

  def assert_proof(encoded, proof_bytes, public_key, previous_counter, app_id) do
    try do
      %{"authenticatorData" => raw_auth, "signature" => raw_sig} = decode(encoded)
      auth = bytes(raw_auth)
      true = byte_size(auth) in 37..1024
      <<rp_id::binary-size(32), _flags, counter::32, _rest::binary>> = auth
      true = rp_id == :crypto.hash(:sha256, app_id)
      true = counter > previous_counter
      nonce = :crypto.hash(:sha256, auth <> :crypto.hash(:sha256, proof_bytes))
      true = :crypto.verify(:ecdsa, :sha256, nonce, bytes(raw_sig), [public_key, :secp256r1])
      {:ok, counter}
    rescue
      _ -> {:error, :invalid_assertion}
    catch
      _, _ -> {:error, :invalid_assertion}
    end
  end

  defp decode(encoded) when is_binary(encoded) and byte_size(encoded) <= 24_576 do
    {:ok, raw} = Base.decode64(encoded)
    {:ok, object, <<>>} = CBOR.decode(raw)
    object
  end

  defp bytes(%CBOR.Tag{tag: :bytes, value: binary}) when is_binary(binary), do: binary
  defp aaguid(:production), do: "appattest" <> <<0::56>>
  defp aaguid(:development), do: "appattestdevelop"

  defp public_key(certificate) do
    info = tbs(cert(certificate, :tbsCertificate), :subjectPublicKeyInfo)
    algorithm = spki(info, :algorithm)
    @ec_oid = alg(algorithm, :algorithm)
    {:namedCurve, @p256_oid} = alg(algorithm, :parameters)
    {:ECPoint, point} = spki(info, :subjectPublicKey)
    <<4, _::binary-size(64)>> = point
    point
  end

  defp valid_chain?(root, chain, now) do
    # OTP retains every path/signature/constraint check. This callback substitutes
    # the application clock only for certificate time, for all certificates.
    clock_check = fn certificate, event, state ->
      case event do
        {:bad_cert, :cert_expired} ->
          if valid_at?(certificate, now), do: {:valid, state}, else: {:fail, :cert_expired}

        {:bad_cert, reason} ->
          {:fail, reason}

        {:extension, _} ->
          {:unknown, state}

        event when event in [:valid, :valid_peer] ->
          if valid_at?(certificate, now), do: {:valid, state}, else: {:fail, :cert_expired}
      end
    end

    valid_at?(:public_key.pkix_decode_cert(root, :otp), now) and
      match?(
        {:ok, _},
        :public_key.pkix_path_validation(root, Enum.reverse(chain),
          verify_fun: {clock_check, nil},
          max_path_length: 2
        )
      )
  end

  defp valid_at?(certificate, now) do
    times = tbs(cert(certificate, :tbsCertificate), :validity)
    first = as_datetime(validity(times, :notBefore))
    last = as_datetime(validity(times, :notAfter))
    DateTime.compare(first, now) != :gt and DateTime.compare(now, last) != :gt
  end

  defp as_datetime({:utcTime, time}) do
    <<year::binary-size(2), rest::binary>> = List.to_string(time)
    year = String.to_integer(year)
    year = if year >= 50, do: year + 1900, else: year + 2000
    as_datetime({:generalTime, String.to_charlist(Integer.to_string(year) <> rest)})
  end

  defp as_datetime({:generalTime, time}) do
    <<year::binary-size(4), month::binary-size(2), day::binary-size(2), hour::binary-size(2),
      minute::binary-size(2), second::binary-size(2), "Z">> = List.to_string(time)

    {:ok, value, 0} =
      DateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z")

    value
  end
end
