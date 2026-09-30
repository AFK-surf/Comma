defmodule SalixSignalProto.ContactDiscovery.X509 do
  @moduledoc """
  X.509 helpers for contact discovery attestation (CRS-11 §5.3 to §5.5):
  PEM chains in one-path order, path validation with CRL checks at a given
  time, CRLs, P-256 ECDSA with raw `r || s` signatures, and the Intel SGX
  extension of a PCK certificate.

  Times are Unix seconds. Path validation (§5.3.1) uses OTP `:public_key`
  for signatures, name chaining, basic constraints, key usage and critical
  extensions; this module checks validity periods, CRL times and revocation
  at the given time itself, because OTP checks them only at the current time.
  """

  import Bitwise

  @p256 {1, 2, 840, 10045, 3, 1, 7}
  @sgx_extension {1, 2, 840, 113_741, 1, 13, 1}
  @authority_key_identifier {2, 5, 29, 35}
  @subject_key_identifier {2, 5, 29, 14}
  @key_usage {2, 5, 29, 15}
  @crl_number {2, 5, 29, 20}

  # Intel chains hold two or three certificates; the bound keeps the search
  # for their order small.
  @max_chain_certificates 10

  @type cert :: %{der: binary(), otp: tuple()}
  @type crl :: %{
          der: binary(),
          issuer: term(),
          this_update: integer(),
          next_update: integer(),
          revoked: [integer()]
        }

  # --- Certificates ------------------------------------------------------

  @doc """
  Decodes PEM data into certificates ordered leaf first, root last (§5.4).
  The PEM entries may come in any order. They must form one sequence from a
  leaf to a self-issued root in which each certificate is issued by the next
  (`issued_by?/2`: names, key identifiers and key usage, no signature) and
  every certificate is used. A missing certificate, or an extra one that fits
  nowhere, rejects. An extra copy of the self-issued root, or a second
  self-issued certificate with the root's subject and key identifier, fits
  after the root and is accepted. Non-certificate entries reject.
  """
  @spec pem_chain(binary()) :: {:ok, [cert()]} | {:error, :invalid_chain}
  def pem_chain(pem) when is_binary(pem) do
    with {:ok, certs} <- decode_pem(pem),
         {:ok, chain} <- order(certs) do
      {:ok, chain}
    else
      _ -> {:error, :invalid_chain}
    end
  end

  defp decode_pem(pem) do
    entries = :public_key.pem_decode(pem)

    if entries != [] and Enum.all?(entries, &match?({:Certificate, _, :not_encrypted}, &1)) do
      {:ok, for({:Certificate, der, _} <- entries, do: %{der: der, otp: decode_cert!(der)})}
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp decode_cert!(der), do: :public_key.pkix_decode_cert(der, :otp)

  # Tries each certificate, in data order, as the first of the sequence, and
  # extends the sequence depth first. Identical copies are tried once at each
  # step.
  defp order(certs) when length(certs) <= @max_chain_certificates do
    entries = Enum.with_index(certs)

    Enum.find_value(entries, :error, fn entry ->
      case extend([entry], List.delete(entries, entry)) do
        {:ok, path} -> {:ok, Enum.map(path, &elem(&1, 0))}
        :error -> nil
      end
    end)
  end

  defp order(_certs), do: :error

  # `path` holds the sequence so far, last certificate first.
  defp extend([{last, _} | _] = path, []),
    do: if(self_issued?(last), do: {:ok, Enum.reverse(path)}, else: :error)

  defp extend([{last, _} | _] = path, rest) do
    rest
    |> Enum.uniq_by(fn {cert, _index} -> cert.der end)
    |> Enum.filter(fn {cert, _index} -> issued_by?(last, cert) end)
    |> Enum.find_value(:error, fn next ->
      case extend([next | path], List.delete(rest, next)) do
        {:ok, _} = ok -> ok
        :error -> nil
      end
    end)
  end

  @doc "True when the certificate's issuer name equals its subject name."
  @spec self_issued?(cert()) :: boolean()
  def self_issued?(%{otp: otp}), do: :public_key.pkix_is_issuer(otp, otp)

  @doc """
  The "issued by" test of §5.4, without a signature check: the issuer name
  of `cert` equals the subject name of `issuer`, the Authority Key Identifier
  of `cert` (if present) equals the Subject Key Identifier of `issuer` (if
  present), and the key usage of `issuer` (if present) allows certificate
  signing.
  """
  @spec issued_by?(cert(), cert()) :: boolean()
  def issued_by?(%{otp: cert} = child, %{otp: issuer} = parent) do
    :public_key.pkix_is_issuer(cert, issuer) and key_identifiers_match?(child, parent) and
      may_sign_certificates?(parent)
  end

  defp key_identifiers_match?(child, parent) do
    case {authority_key_id(child), subject_key_id(parent)} do
      {id, id} -> true
      {nil, _} -> true
      {_, nil} -> true
      _ -> false
    end
  end

  defp authority_key_id(cert) do
    case extension(cert, @authority_key_identifier) do
      {:AuthorityKeyIdentifier, id, _issuer, _serial} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp subject_key_id(cert) do
    case extension(cert, @subject_key_identifier) do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp may_sign_certificates?(cert) do
    case extension(cert, @key_usage) do
      nil -> true
      usage when is_list(usage) -> :keyCertSign in usage
      _ -> false
    end
  end

  defp extension(%{otp: otp}, oid) do
    Enum.find_value(List.wrap(tbs(otp) |> elem(10)), fn
      {:Extension, ^oid, _critical, value} -> value
      _ -> nil
    end)
  end

  @doc "True when `notBefore <= t <= notAfter`."
  @spec valid_at?(cert(), integer()) :: boolean()
  def valid_at?(%{otp: otp}, t) do
    {:Validity, not_before, not_after} = tbs(otp) |> elem(5)

    with {:ok, from} <- asn1_time(not_before),
         {:ok, until} <- asn1_time(not_after) do
      from <= t and t <= until
    else
      _ -> false
    end
  end

  @doc "The P-256 public key of a certificate as an uncompressed point."
  @spec p256_public_key(cert()) :: {:ok, <<_::520>>} | :error
  def p256_public_key(%{otp: otp}) do
    case tbs(otp) |> elem(7) do
      {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, _, {:namedCurve, @p256}},
       {:ECPoint, <<4, _::binary-size(64)>> = point}} ->
        {:ok, point}

      _ ->
        :error
    end
  end

  @doc """
  True when the self-issued `root` carries `pinned` (a 65-byte uncompressed
  P-256 point) as its key and its signature verifies under that key.
  """
  @spec pinned_root?(cert(), binary()) :: boolean()
  def pinned_root?(%{der: der} = root, pinned) do
    self_issued?(root) and p256_public_key(root) == {:ok, pinned} and
      safe(fn -> :public_key.pkix_verify(der, ec_key(pinned)) end)
  end

  @doc """
  Validates `chain` (leaf first, as from `pem_chain/1`) against the trust
  `anchor` at time `t` (§5.3.1).

  The path is the chain's certificates before its first self-issued one. The
  self-issued certificates at the end are root copies: they are not the
  anchor, are not part of the path, and their keys and signatures are not
  checked (`pem_chain/1` has already applied §5.4 to them; their validity
  periods are checked with `valid_at?/2`). For the TCB-info signing chain the
  last certificate is the anchor itself.

  Each path certificate must verify under the next one and the last under the
  anchor, with name chaining, issuer constraints and critical extensions
  checked by OTP path validation. Every path certificate and the anchor must
  be covered by a CRL in `crls` from its issuer that verifies under the
  issuer's key and is current at `t` (`thisUpdate <= t < nextUpdate`), and
  must not be listed in it. Validity periods are checked separately
  (`valid_at?/2`).
  """
  @spec validate_path([cert()], cert(), [crl()], integer()) :: :ok | {:error, term()}
  def validate_path(chain, anchor, crls, t) do
    {path, copies} = Enum.split_while(chain, &(not self_issued?(&1)))

    cond do
      copies == [] or not Enum.all?(copies, &self_issued?/1) ->
        {:error, :untrusted_root}

      not path_valid?(anchor, path) ->
        {:error, :path_validation}

      not Enum.all?(
        Enum.zip(path ++ [anchor], tl(path ++ [anchor]) ++ [anchor]),
        fn {cert, issuer} -> not_revoked?(cert, issuer, crls, t) end
      ) ->
        {:error, :revocation}

      true ->
        :ok
    end
  end

  defp path_valid?(_anchor, []), do: true

  defp path_valid?(%{der: anchor}, path) do
    verify_fun =
      {fn
         _cert, {:bad_cert, :cert_expired}, state -> {:valid, state}
         _cert, {:bad_cert, {:cert_expired, _}}, state -> {:valid, state}
         _cert, {:bad_cert, reason}, _state -> {:fail, reason}
         _cert, {:extension, _}, state -> {:unknown, state}
         _cert, :valid, state -> {:valid, state}
         _cert, :valid_peer, state -> {:valid, state}
       end, nil}

    chain = path |> Enum.reverse() |> Enum.map(& &1.der)

    match?({:ok, _}, :public_key.pkix_path_validation(anchor, chain, verify_fun: verify_fun))
  rescue
    _ -> false
  end

  # The CRLs from the certificate's issuer (by name) that are current at `t`;
  # at least one must verify under the issuer's key, and none may list the
  # certificate.
  defp not_revoked?(%{otp: otp}, %{der: issuer_der}, crls, t) do
    tbs = tbs(otp)
    serial = elem(tbs, 2)
    issuer_name = :public_key.pkix_normalize_name(elem(tbs, 4))

    case Enum.filter(crls, &(&1.issuer == issuer_name and current?(&1, t))) do
      [] ->
        false

      candidates ->
        Enum.any?(candidates, &safe(fn -> :public_key.pkix_crl_verify(&1.der, issuer_der) end)) and
          Enum.all?(candidates, &(serial not in &1.revoked))
    end
  rescue
    _ -> false
  end

  @doc "True when `thisUpdate <= t < nextUpdate` (§5.3.1, CRL time)."
  @spec current?(crl(), integer()) :: boolean()
  def current?(%{this_update: this_update, next_update: next_update}, t),
    do: this_update <= t and t < next_update

  # --- CRLs --------------------------------------------------------------

  @doc """
  Decodes a DER CRL. It must carry the Authority Key Identifier and CRL
  Number extensions and a next-update time (§5.5).
  """
  @spec crl(binary()) :: {:ok, crl()} | {:error, :invalid_crl}
  def crl(der) when is_binary(der) do
    {:CertificateList, tbs, _alg, _sig} = :public_key.der_decode(:CertificateList, der)
    {:TBSCertList, _v, _sig, _issuer, this_update, next_update, revoked, extensions} = tbs
    ids = if is_list(extensions), do: Enum.map(extensions, &elem(&1, 1)), else: []

    with true <- @authority_key_identifier in ids and @crl_number in ids,
         {:ok, this_update} <- asn1_time(this_update),
         {:ok, next_update} <- asn1_time(next_update) do
      {:ok,
       %{
         der: der,
         issuer: :public_key.pkix_crl_issuer(der),
         this_update: this_update,
         next_update: next_update,
         revoked: revoked_serials(revoked)
       }}
    else
      _ -> {:error, :invalid_crl}
    end
  rescue
    _ -> {:error, :invalid_crl}
  end

  defp revoked_serials(list) when is_list(list), do: Enum.map(list, &elem(&1, 1))
  defp revoked_serials(_none), do: []

  @doc """
  True when the CRL's signature verifies under `pinned`, a 65-byte
  uncompressed P-256 point.
  """
  @spec crl_signed_by?(crl(), binary()) :: boolean()
  def crl_signed_by?(%{der: der}, pinned) do
    {:ok, {:sequence, body}, ""} = der_read(der)
    {:ok, {:sequence, _} = _tbs, tbs_raw, rest} = der_read_raw(body)
    {:ok, _alg, rest} = der_read(rest)
    {:ok, {:bit_string, <<0, signature::binary>>}, ""} = der_read(rest)

    safe(fn -> :public_key.verify(tbs_raw, :sha256, signature, ec_key(pinned)) end)
  rescue
    _ -> false
  end

  # --- Signatures --------------------------------------------------------

  @doc """
  Verifies a raw 64-byte `r || s` ECDSA P-256 SHA-256 signature over
  `message` under `public_key`: a 64-byte `x || y` or 65-byte uncompressed
  point.
  """
  @spec verify_p256(binary(), binary(), binary()) :: boolean()
  def verify_p256(message, <<r::unsigned-big-256, s::unsigned-big-256>>, public_key) do
    point =
      case public_key do
        <<_::binary-size(64)>> -> <<4, public_key::binary>>
        _ -> public_key
      end

    signature = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    safe(fn -> :public_key.verify(message, :sha256, signature, ec_key(point)) end)
  end

  def verify_p256(_message, _signature, _public_key), do: false

  defp ec_key(<<4, _::binary-size(64)>> = point), do: {{:ECPoint, point}, {:namedCurve, @p256}}

  defp safe(fun) do
    fun.() == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # --- Intel SGX extension ------------------------------------------------

  @doc """
  Reads the Intel SGX extension (OID 1.2.840.113741.1.13.1) of a PCK
  certificate (§5.4): `%{cpu_svn_components: [16 integers], pce_svn:,
  pce_id: <<_::16>>, fmspc: <<_::48>>}`. PPID, TCB, PCE-ID, FMSPC and SGX
  type must be present.
  """
  @spec sgx_extension(cert()) :: {:ok, map()} | {:error, :invalid_sgx_extension}
  def sgx_extension(%{otp: otp}) do
    extensions = tbs(otp) |> elem(10)

    with [value] <-
           for({:Extension, @sgx_extension, _, value} <- List.wrap(extensions), do: value),
         {:ok, entries} <- oid_entries(value, Tuple.to_list(@sgx_extension)),
         {:octet_string, <<_::binary-size(16)>>} <- Map.get(entries, 1),
         {:sequence, tcb_body} <- Map.get(entries, 2),
         {:octet_string, <<_::binary-size(2)>> = pce_id} <- Map.get(entries, 3),
         {:octet_string, <<_::binary-size(6)>> = fmspc} <- Map.get(entries, 4),
         {:enumerated, _} <- Map.get(entries, 5),
         {:ok, tcb} <- oid_entries_of(tcb_body, Tuple.to_list(@sgx_extension) ++ [2], %{}),
         {:ok, components} <- svn_components(tcb),
         {:integer, pce_svn} when pce_svn >= 0 <- Map.get(tcb, 17),
         {:octet_string, <<_::binary-size(16)>>} <- Map.get(tcb, 18) do
      {:ok, %{cpu_svn_components: components, pce_svn: pce_svn, pce_id: pce_id, fmspc: fmspc}}
    else
      _ -> {:error, :invalid_sgx_extension}
    end
  end

  defp svn_components(tcb) do
    components = for i <- 1..16, do: Map.get(tcb, i)

    if Enum.all?(components, &match?({:integer, n} when n >= 0, &1)),
      do: {:ok, Enum.map(components, &elem(&1, 1))},
      else: :error
  end

  # SEQUENCE OF SEQUENCE { OID <prefix>.n, value } -> %{n => value}.
  defp oid_entries(der, prefix) do
    case der_read(der) do
      {:ok, {:sequence, body}, ""} -> oid_entries_of(body, prefix, %{})
      _ -> :error
    end
  end

  defp oid_entries_of("", _prefix, acc), do: {:ok, acc}

  defp oid_entries_of(body, prefix, acc) do
    with {:ok, {:sequence, entry}, rest} <- der_read(body),
         {:ok, {:oid, oid}, value_der} <- der_read(entry),
         {:ok, value, ""} <- der_read(value_der),
         [index] <- arcs_after(Tuple.to_list(oid), prefix),
         false <- Map.has_key?(acc, index) do
      oid_entries_of(rest, prefix, Map.put(acc, index, value))
    else
      _ -> :error
    end
  end

  defp arcs_after([arc | arcs], [arc | prefix]), do: arcs_after(arcs, prefix)
  defp arcs_after(arcs, []), do: arcs
  defp arcs_after(_arcs, _prefix), do: :error

  # --- Minimal DER ---------------------------------------------------------

  @doc false
  def der_read(bytes) do
    case der_read_raw(bytes) do
      {:ok, value, _raw, rest} -> {:ok, value, rest}
      :error -> :error
    end
  end

  defp der_read_raw(<<tag, rest::binary>> = all) do
    with {:ok, length, rest} <- der_length(rest),
         <<content::binary-size(^length), after_value::binary>> <- rest do
      raw_size = byte_size(all) - byte_size(after_value)
      {:ok, der_value(tag, content), binary_part(all, 0, raw_size), after_value}
    else
      _ -> :error
    end
  end

  defp der_read_raw(_bytes), do: :error

  defp der_length(<<0::1, length::7, rest::binary>>), do: {:ok, length, rest}

  defp der_length(<<1::1, count::7, rest::binary>>) when count in 1..4 do
    case rest do
      <<length::unsigned-big-size(^count * 8), rest::binary>> when length >= 128 ->
        {:ok, length, rest}

      _ ->
        :error
    end
  end

  defp der_length(_bytes), do: :error

  defp der_value(0x30, content), do: {:sequence, content}
  defp der_value(0x04, content), do: {:octet_string, content}
  defp der_value(0x03, content), do: {:bit_string, content}
  defp der_value(0x06, content), do: {:oid, decode_oid(content)}
  defp der_value(0x02, content), do: {:integer, decode_integer(content)}
  defp der_value(0x0A, content), do: {:enumerated, decode_integer(content)}
  defp der_value(0x01, content), do: {:boolean, content}
  defp der_value(tag, content), do: {tag, content}

  defp decode_integer(""), do: :invalid

  defp decode_integer(content) do
    size = bit_size(content)
    <<value::signed-big-size(^size)>> = content
    value
  end

  defp decode_oid(<<first, rest::binary>>) do
    arcs = decode_arcs(rest, 0, [])
    List.to_tuple([div(min(first, 80), 40), first - 40 * div(min(first, 80), 40) | arcs])
  end

  defp decode_oid(""), do: {}

  defp decode_arcs(<<>>, _acc, arcs), do: Enum.reverse(arcs)

  defp decode_arcs(<<1::1, bits::7, rest::binary>>, acc, arcs),
    do: decode_arcs(rest, acc <<< 7 ||| bits, arcs)

  defp decode_arcs(<<0::1, bits::7, rest::binary>>, acc, arcs),
    do: decode_arcs(rest, 0, [acc <<< 7 ||| bits | arcs])

  # --- Helpers -----------------------------------------------------------

  defp tbs({:OTPCertificate, tbs, _alg, _sig}), do: tbs

  @doc "Converts an ASN.1 UTCTime or GeneralizedTime (`Z` form) to Unix seconds."
  @spec asn1_time(term()) :: {:ok, integer()} | :error
  def asn1_time({:utcTime, chars}) do
    case to_string(chars) do
      <<yy::binary-size(2), rest::binary-size(10), "Z">> ->
        year = String.to_integer(yy)
        full_time("#{if year >= 50, do: 1900 + year, else: 2000 + year}", rest)

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  def asn1_time({:generalTime, chars}) do
    case to_string(chars) do
      <<yyyy::binary-size(4), rest::binary-size(10), "Z">> -> full_time(yyyy, rest)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def asn1_time(_other), do: :error

  defp full_time(
         year,
         <<mo::binary-size(2), d::binary-size(2), h::binary-size(2), mi::binary-size(2),
           s::binary-size(2)>>
       ) do
    with {:ok, date} <-
           Date.new(String.to_integer(year), String.to_integer(mo), String.to_integer(d)),
         {:ok, time} <-
           Time.new(String.to_integer(h), String.to_integer(mi), String.to_integer(s)),
         {:ok, datetime} <- DateTime.new(date, time) do
      {:ok, DateTime.to_unix(datetime)}
    else
      _ -> :error
    end
  end
end
