defmodule SalixSignalProto.Test.SgxAttestation do
  @moduledoc false
  # Builds synthetic contact discovery attestation messages (CRS-11 §5) from a
  # test PKI that stands in for Intel's: a P-256 root, a platform CA, a PCK
  # leaf with the SGX extension, a TCB signing certificate, both CRLs, signed
  # TCB info and QE identity documents, and an ECDSA quote version 3 followed
  # by the custom claims. `build/1` returns the message with pins that match
  # the test PKI, so `Attestation.verify/3` accepts it; each option changes one
  # part so that a test can check the matching rejection.
  #
  # No captured or oracle attestation exists yet (CRS-11 open question 1); the
  # layouts here come only from CRS-11 §5.

  import Bitwise

  @now 1_790_294_400
  @day 86_400
  @p256 {1, 2, 840, 10045, 3, 1, 7}
  @ecdsa_sha256 {1, 2, 840, 10045, 4, 3, 2}
  @sgx [1, 2, 840, 113_741, 1, 13, 1]

  def now, do: @now

  @doc """
  Options (all optional): `:now` (Unix seconds; default `now/0`),
  `:noise_key` (32 bytes), `:mrenclave`,
  `:attributes` (16 bytes of the enclave report), `:claims` (list of
  `{name, value}`), `:claims_buffer` (raw bytes that replace the claims),
  `:report_data` (64 bytes), `:tcb_levels` (maps with `components`,
  `pce_svn`, `status`, `advisories`), `:tcb_version` (2 or 3),
  `:cpu_svn_components`, `:pce_svn`, `:fmspc`, `:tcb_fmspc`,
  `:tcb_next_update`, `:tcb_evaluation`, `:qe_levels`, `:qe_isvsvn`,
  `:qe_mrsigner` (in the identity), `:qe_vendor_id`, `:crl_next_update`,
  `:revoke` (`:pck_leaf` or `:platform_ca`), `:pck_leaf_not_after`,
  `:tamper` (`:quote_signature`, `:qe_report_signature`,
  `:tcb_info_signature`, `:qe_identity_signature`, `:qe_report_data`),
  `:pck_chain` (`:missing_root`, `:extra_cert`, `:extra_root`,
  `:extra_leaf`), `:root_crl_signer` (`:platform_ca`), `:crl_extensions`
  (`:no_number`), `:crl_this_update`, `:root_copy` (a self-issued root copy
  with the root's subject that replaces the root at the end of one chain:
  `:other_key` keeps the root's key identifier with another key,
  `:other_key_id` also changes the key identifier, `:no_cert_sign` has a key
  usage without certificate signing, `:expired` is not valid at `t`,
  `:no_key_id` has no key identifiers, `:no_ca` has no CA flag) and
  `:root_copy_in` (`:pck` (default), `:qe` or `:pck_crl`: the chain whose
  root is replaced).

  Every certificate carries a Subject Key Identifier and an Authority Key
  Identifier (SHA-1 of the public point), as Intel's do.
  """
  def build(opts \\ []) do
    now = Keyword.get(opts, :now, @now)
    noise_key = Keyword.get(opts, :noise_key, :crypto.strong_rand_bytes(32))
    mrenclave = Keyword.get(opts, :mrenclave, :binary.copy(<<0xA5>>, 32))

    root_key = ec_key()
    platform_key = ec_key()
    tcb_key = ec_key()
    pck_key = ec_key()
    attestation_key = ec_key()

    root_name = name("Test SGX Root CA")
    platform_name = name("Test SGX PCK Platform CA")

    root =
      cert(%{
        serial: 1,
        issuer: root_name,
        subject: root_name,
        key: root_key,
        signer: root_key,
        ca: true,
        now: now
      })

    root_copy = root_copy(opts[:root_copy], root, root_key, root_name, now)

    platform =
      cert(%{
        serial: 2,
        issuer: root_name,
        subject: platform_name,
        key: platform_key,
        signer: root_key,
        ca: true,
        now: now
      })

    tcb_signer =
      cert(%{
        serial: 3,
        issuer: root_name,
        subject: name("Test SGX TCB Signing"),
        key: tcb_key,
        signer: root_key,
        ca: false,
        now: now
      })

    cpu_svn = Keyword.get(opts, :cpu_svn_components, List.duplicate(5, 16))
    pce_svn = Keyword.get(opts, :pce_svn, 11)
    fmspc = Keyword.get(opts, :fmspc, <<0x00, 0x60, 0x6A, 0x00, 0x00, 0x00>>)

    pck_leaf =
      cert(%{
        serial: 4,
        issuer: platform_name,
        subject: name("Test SGX PCK Certificate"),
        key: pck_key,
        signer: platform_key,
        ca: false,
        now: now,
        not_after: Keyword.get(opts, :pck_leaf_not_after, now + 5 * 365 * @day),
        extensions: [
          {:Extension, List.to_tuple(@sgx), false, sgx_extension(cpu_svn, pce_svn, fmspc)}
        ]
      })

    revoked =
      case Keyword.get(opts, :revoke) do
        :pck_leaf -> %{pck: [4], root: []}
        :platform_ca -> %{pck: [], root: [2]}
        nil -> %{pck: [], root: []}
      end

    crl_next_update = Keyword.get(opts, :crl_next_update, now + 30 * @day)

    crl_opts = %{
      now: now,
      this_update: Keyword.get(opts, :crl_this_update, now - @day),
      next_update: crl_next_update,
      extensions: Keyword.get(opts, :crl_extensions)
    }

    root_crl_signer =
      if opts[:root_crl_signer] == :platform_ca,
        do: {platform, platform_key},
        else: {root, root_key}

    root_crl = crl(elem(root_crl_signer, 0), elem(root_crl_signer, 1), revoked.root, crl_opts)
    pck_crl = crl(platform, platform_key, revoked.pck, crl_opts)

    # --- Quote ---
    qe_vendor_id = Keyword.get(opts, :qe_vendor_id, :binary.copy(<<0x93>>, 16))
    qe_mrsigner = :binary.copy(<<0x8C>>, 32)
    qe_isvsvn = Keyword.get(opts, :qe_isvsvn, 8)
    attestation_public = public_point(attestation_key) |> binary_part(1, 64)
    qe_auth = :binary.copy(<<0x2A>>, 32)

    claims_buffer =
      Keyword.get_lazy(opts, :claims_buffer, fn ->
        claims_buffer(Keyword.get(opts, :claims, [{"pk", noise_key}]))
      end)

    report_data =
      Keyword.get(opts, :report_data, :crypto.hash(:sha256, claims_buffer) <> <<0::256>>)

    header =
      <<3::little-16, 2::little-16, 0::32, 1::little-16, 2::little-16, qe_vendor_id::binary,
        0::160>>

    report =
      report_body(%{
        attributes: Keyword.get(opts, :attributes, <<0x05, 0::120>>),
        mrenclave: mrenclave,
        mrsigner: :binary.copy(<<0x11>>, 32),
        isvprodid: 3,
        isvsvn: 4,
        report_data: report_data
      })

    quote_signature =
      maybe_tamper(sign(header <> report, attestation_key), opts, :quote_signature)

    qe_report_data =
      if opts[:tamper] == :qe_report_data,
        do: :binary.copy(<<1>>, 64),
        else: :crypto.hash(:sha256, attestation_public <> qe_auth) <> <<0::256>>

    qe_report =
      report_body(%{
        attributes: <<0x11, 0::120>>,
        mrenclave: :binary.copy(<<0x77>>, 32),
        mrsigner: qe_mrsigner,
        isvprodid: 1,
        isvsvn: qe_isvsvn,
        report_data: qe_report_data
      })

    qe_report_signature = maybe_tamper(sign(qe_report, pck_key), opts, :qe_report_signature)

    copy_in = Keyword.get(opts, :root_copy_in, :pck)
    chain_root = fn chain -> if copy_in == chain, do: root_copy, else: root end

    pck_chain =
      case opts[:pck_chain] do
        :missing_root -> [pck_leaf, platform]
        :extra_cert -> [platform, pck_leaf, root, tcb_signer]
        :extra_root -> [root, platform, pck_leaf, root]
        :extra_leaf -> [platform, pck_leaf, root, pck_leaf]
        nil -> [platform, pck_leaf, chain_root.(:pck)]
      end

    cert_data = pem(pck_chain) <> <<0>>

    signature_data =
      quote_signature <>
        attestation_public <>
        qe_report <>
        qe_report_signature <>
        <<byte_size(qe_auth)::little-16>> <>
        qe_auth <> <<5::little-16, byte_size(cert_data)::little-32>> <> cert_data

    evidence =
      header <>
        report <> <<byte_size(signature_data)::little-32>> <> signature_data <> claims_buffer

    # --- Collateral ---
    tcb_levels =
      Keyword.get(opts, :tcb_levels, [
        %{components: List.duplicate(5, 16), pce_svn: 11, status: "UpToDate", advisories: []},
        %{components: List.duplicate(2, 16), pce_svn: 7, status: "OutOfDate", advisories: []}
      ])

    tcb_body =
      JSON.encode!(%{
        "id" => "SGX",
        "version" => Keyword.get(opts, :tcb_version, 3),
        "issueDate" => iso(now - @day),
        "nextUpdate" => iso(Keyword.get(opts, :tcb_next_update, now + 30 * @day)),
        "fmspc" => Base.encode16(Keyword.get(opts, :tcb_fmspc, fmspc)),
        "pceId" => "0000",
        "tcbType" => 0,
        "tcbEvaluationDataNumber" => Keyword.get(opts, :tcb_evaluation, 21),
        "tcbLevels" =>
          Enum.map(tcb_levels, &tcb_level(&1, Keyword.get(opts, :tcb_version, 3), now))
      })

    qe_body =
      JSON.encode!(%{
        "id" => "QE",
        "version" => 2,
        "issueDate" => iso(now - @day),
        "nextUpdate" => iso(Keyword.get(opts, :tcb_next_update, now + 30 * @day)),
        "tcbEvaluationDataNumber" => Keyword.get(opts, :tcb_evaluation, 21),
        "miscselect" => "00000000",
        "miscselectMask" => "FFFFFFFF",
        "attributes" => "11000000000000000000000000000000",
        "attributesMask" => "FBFFFFFFFFFFFFFF0000000000000000",
        "mrsigner" => Base.encode16(Keyword.get(opts, :qe_mrsigner, qe_mrsigner)),
        "isvprodid" => 1,
        "tcbLevels" =>
          Keyword.get(opts, :qe_levels, [
            %{"tcb" => %{"isvsvn" => 8}, "tcbDate" => iso(now), "tcbStatus" => "UpToDate"},
            %{"tcb" => %{"isvsvn" => 6}, "tcbDate" => iso(now), "tcbStatus" => "OutOfDate"}
          ])
      })

    tcb_info = signed_document("tcbInfo", tcb_body, tcb_key, opts[:tamper] == :tcb_info_signature)

    qe_identity =
      signed_document(
        "enclaveIdentity",
        qe_body,
        tcb_key,
        opts[:tamper] == :qe_identity_signature
      )

    tcb_chain = pem([tcb_signer, root])

    endorsements =
      endorsements([
        <<1::little-32>>,
        tcb_info <> <<0>>,
        tcb_chain,
        pck_crl,
        root_crl,
        pem([chain_root.(:pck_crl), platform]),
        qe_identity <> <<0>>,
        pem([tcb_signer, chain_root.(:qe)]),
        "2026-09-25T00:00:00Z"
      ])

    message = message(:binary.copy(<<9>>, 32), evidence, endorsements)

    %{
      message: message,
      evidence: evidence,
      endorsements: endorsements,
      noise_key: noise_key,
      now: now,
      pins: %{
        mrenclave: mrenclave,
        root_public_key: public_point(root_key),
        qe_vendor_id: qe_vendor_id,
        accepted_advisories: ["INTEL-SA-00615", "INTEL-SA-00657"],
        minimum_evaluation_data_number: 21
      }
    }
  end

  @doc "The proto3 attestation message: field 1, 2 and 3 (CRS-11 §5.1)."
  def message(public_key, evidence, endorsements) do
    field(1, public_key) <> field(2, evidence) <> field(3, endorsements)
  end

  def claims_buffer(claims) do
    body =
      for {name, value} <- claims, into: <<>> do
        <<byte_size(name)::little-64, byte_size(value)::little-64, name::binary, value::binary>>
      end

    <<1::little-64, length(claims)::little-64, body::binary>>
  end

  def endorsements(fields) do
    {offsets, _} = Enum.map_reduce(fields, 0, fn f, at -> {at, at + byte_size(f)} end)
    data = IO.iodata_to_binary(fields)
    offset_bytes = for o <- offsets, into: <<>>, do: <<o::little-32>>
    size = 16 + byte_size(offset_bytes) + byte_size(data)

    <<1::little-32, 2::little-32, size::little-32, length(fields)::little-32,
      offset_bytes::binary, data::binary>>
  end

  # --- Pieces ---------------------------------------------------------------

  defp report_body(r) do
    <<0::128, 0::32, 0::96, 0::128, r.attributes::binary-size(16), r.mrenclave::binary-size(32),
      0::256, r.mrsigner::binary-size(32), 0::256, 0::512, r.isvprodid::little-16,
      r.isvsvn::little-16, 0::little-16, 0::336, 0::128, r.report_data::binary-size(64)>>
  end

  defp tcb_level(level, 3, now) do
    %{
      "tcb" => %{
        "sgxtcbcomponents" => Enum.map(level.components, &%{"svn" => &1}),
        "pcesvn" => level.pce_svn
      },
      "tcbDate" => iso(now),
      "tcbStatus" => level.status,
      "advisoryIDs" => level.advisories
    }
  end

  defp tcb_level(level, 2, now) do
    components =
      level.components
      |> Enum.with_index(1)
      |> Map.new(fn {svn, i} ->
        {"sgxtcbcomp" <> String.pad_leading("#{i}", 2, "0") <> "svn", svn}
      end)

    %{
      "tcb" => Map.put(components, "pcesvn", level.pce_svn),
      "tcbDate" => iso(now),
      "tcbStatus" => level.status
    }
  end

  # The signature covers the exact body bytes; the spaces around them check
  # that the verifier does not re-serialize.
  defp signed_document(key, body, signer, tamper?) do
    signature = sign(body, signer)
    signature = if tamper?, do: flip(signature), else: signature
    ~s({ "#{key}" : #{body} , "signature":"#{Base.encode16(signature, case: :lower)}"})
  end

  defp maybe_tamper(signature, opts, what),
    do: if(opts[:tamper] == what, do: flip(signature), else: signature)

  defp flip(<<first, rest::binary>>), do: <<bxor(first, 1), rest::binary>>

  defp sgx_extension(cpu_svn, pce_svn, fmspc) do
    tcb =
      Enum.with_index(cpu_svn, 1)
      |> Enum.map(fn {svn, i} -> der_seq([der_oid(@sgx ++ [2, i]), der_int(svn)]) end)

    tcb =
      tcb ++
        [
          der_seq([der_oid(@sgx ++ [2, 17]), der_int(pce_svn)]),
          der_seq([der_oid(@sgx ++ [2, 18]), der_tlv(0x04, :binary.list_to_bin(cpu_svn))])
        ]

    der_seq([
      der_seq([der_oid(@sgx ++ [1]), der_tlv(0x04, :binary.copy(<<0x44>>, 16))]),
      der_seq([der_oid(@sgx ++ [2]), der_seq(tcb)]),
      der_seq([der_oid(@sgx ++ [3]), der_tlv(0x04, <<0, 0>>)]),
      der_seq([der_oid(@sgx ++ [4]), der_tlv(0x04, fmspc)]),
      der_seq([der_oid(@sgx ++ [5]), der_tlv(0x0A, <<0>>)])
    ])
  end

  # --- X.509 -------------------------------------------------------------

  defp ec_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  defp public_point({:ECPrivateKey, _, _, _, point, _}), do: point

  defp name(common_name) do
    {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, common_name}}]]}
  end

  # A self-issued certificate with the root's subject, for the root-copy
  # rules of CRS-11 §5.3.1. Each variant uses a key other than the root's.
  defp root_copy(nil, root, _root_key, _root_name, _now), do: root

  defp root_copy(variant, _root, root_key, root_name, now) do
    other = ec_key()

    spec = %{
      serial: 1,
      issuer: root_name,
      subject: root_name,
      key: other,
      signer: other,
      ca: true,
      now: now,
      ski: key_id(root_key),
      aki: key_id(root_key)
    }

    spec =
      case variant do
        :other_key -> spec
        :other_key_id -> %{spec | ski: key_id(other), aki: key_id(other)}
        :no_cert_sign -> Map.put(spec, :key_usage, [:digitalSignature, :cRLSign])
        :expired -> Map.put(spec, :not_after, now + 3600)
        :no_key_id -> %{spec | ski: nil, aki: nil}
        :no_ca -> Map.put(spec, :basic_constraints, false)
      end

    cert(spec)
  end

  defp key_id(key), do: :crypto.hash(:sha, public_point(key))

  defp cert(spec) do
    now = spec.now
    not_after = Map.get(spec, :not_after, now + 5 * 365 * @day)

    key_usage =
      Map.get_lazy(spec, :key_usage, fn ->
        if spec.ca, do: [:keyCertSign, :cRLSign], else: [:digitalSignature, :nonRepudiation]
      end)

    basic_constraints =
      if spec.ca and Map.get(spec, :basic_constraints, true),
        do: [{:Extension, {2, 5, 29, 19}, true, {:BasicConstraints, true, :asn1_NOVALUE}}],
        else: []

    ski = Map.get_lazy(spec, :ski, fn -> key_id(spec.key) end)
    aki = Map.get_lazy(spec, :aki, fn -> key_id(spec.signer) end)

    key_ids =
      if(ski, do: [{:Extension, {2, 5, 29, 14}, false, ski}], else: []) ++
        if aki,
          do: [
            {:Extension, {2, 5, 29, 35}, false,
             {:AuthorityKeyIdentifier, aki, :asn1_NOVALUE, :asn1_NOVALUE}}
          ],
          else: []

    base_extensions =
      basic_constraints ++ [{:Extension, {2, 5, 29, 15}, true, key_usage}] ++ key_ids

    tbs =
      {:OTPTBSCertificate, :v3, spec.serial, {:SignatureAlgorithm, @ecdsa_sha256, :asn1_NOVALUE},
       spec.issuer, {:Validity, utc(now - 365 * @day), utc(not_after)}, spec.subject,
       {:OTPSubjectPublicKeyInfo,
        {:PublicKeyAlgorithm, {1, 2, 840, 10045, 2, 1}, {:namedCurve, @p256}},
        {:ECPoint, public_point(spec.key)}}, :asn1_NOVALUE, :asn1_NOVALUE,
       base_extensions ++ Map.get(spec, :extensions, [])}

    :public_key.pkix_sign(tbs, spec.signer)
  end

  defp crl(issuer_der, issuer_key, revoked_serials, opts) do
    {:Certificate, issuer_tbs, _, _} = :public_key.pkix_decode_cert(issuer_der, :plain)
    issuer_name = elem(issuer_tbs, 6)
    algorithm = {:AlgorithmIdentifier, @ecdsa_sha256, :asn1_NOVALUE}

    revoked =
      case revoked_serials do
        [] ->
          :asn1_NOVALUE

        serials ->
          for s <- serials,
              do: {:TBSCertList_revokedCertificates_SEQOF, s, utc(opts.now - @day), :asn1_NOVALUE}
      end

    aki = der_seq([der_tlv(0x80, :crypto.hash(:sha, public_point(issuer_key)))])

    extensions =
      [{:Extension, {2, 5, 29, 35}, false, aki}] ++
        if(opts.extensions == :no_number,
          do: [],
          else: [{:Extension, {2, 5, 29, 20}, false, der_int(1)}]
        )

    tbs =
      {:TBSCertList, :v2, algorithm, issuer_name, utc(opts.this_update), utc(opts.next_update),
       revoked, extensions}

    tbs_der = :public_key.der_encode(:TBSCertList, tbs)
    signature = :public_key.sign(tbs_der, :sha256, issuer_key)
    :public_key.der_encode(:CertificateList, {:CertificateList, tbs, algorithm, signature})
  end

  defp pem(ders), do: :public_key.pem_encode(for d <- ders, do: {:Certificate, d, :not_encrypted})

  defp sign(message, key) do
    der = :public_key.sign(message, :sha256, key)
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::256, s::256>>
  end

  defp utc(unix) do
    dt = DateTime.from_unix!(unix)

    {:utcTime,
     to_charlist(
       :io_lib.format("~2..0B~2..0B~2..0B~2..0B~2..0B~2..0BZ", [
         rem(dt.year, 100),
         dt.month,
         dt.day,
         dt.hour,
         dt.minute,
         dt.second
       ])
     )}
  end

  defp iso(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp field(number, bytes), do: <<number <<< 3 ||| 2>> <> varint(byte_size(bytes)) <> bytes

  defp varint(v) when v < 0x80, do: <<v>>
  defp varint(v), do: <<(v &&& 0x7F) ||| 0x80, varint(v >>> 7)::binary>>

  # --- DER -----------------------------------------------------------------

  defp der_seq(items), do: der_tlv(0x30, IO.iodata_to_binary(items))

  defp der_tlv(tag, content), do: <<tag>> <> der_len(byte_size(content)) <> content

  defp der_len(n) when n < 128, do: <<n>>

  defp der_len(n) do
    bytes = :binary.encode_unsigned(n)
    <<0x80 ||| byte_size(bytes)>> <> bytes
  end

  defp der_int(n) do
    bytes = :binary.encode_unsigned(n)
    bytes = if :binary.first(bytes) >= 0x80, do: <<0>> <> bytes, else: bytes
    der_tlv(0x02, bytes)
  end

  defp der_oid([a, b | rest]) do
    body = for arc <- rest, into: <<a * 40 + b>>, do: base128(arc)
    der_tlv(0x06, body)
  end

  defp base128(n) when n < 128, do: <<n>>

  defp base128(n) do
    groups =
      Stream.unfold(n, fn
        0 -> nil
        v -> {v &&& 0x7F, v >>> 7}
      end)
      |> Enum.reverse()

    {init, [last]} = Enum.split(groups, -1)
    IO.iodata_to_binary(Enum.map(init, &(&1 ||| 0x80)) ++ [last])
  end
end
