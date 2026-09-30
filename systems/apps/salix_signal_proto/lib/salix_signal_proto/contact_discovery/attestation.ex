defmodule SalixSignalProto.ContactDiscovery.Attestation do
  @moduledoc """
  Verification of the contact discovery enclave's SGX attestation message
  (CRS-11 §5). The client accepts the enclave only when every check of
  §5.3 passes; the result is the attested Noise responder static key (the
  `pk` claim). Every failure rejects: contact discovery fails closed.

  The message (§5.1) is a proto3 message with field 1 (public key, ignored),
  field 2 (evidence: an SGX ECDSA quote version 3 followed by the custom
  claims buffer, §5.4) and field 3 (endorsements: Intel collateral, §5.5).

  All time checks use `t = now + 24 hours` (§5.2). The pinned values for
  each environment come from `pins/1`; tests may pass their own.
  """

  alias SalixSignalProto.ContactDiscovery.{Collateral, X509}

  @clock_allowance_s 24 * 60 * 60

  @production_mrenclave Base.decode16!(
                          "15637fa1e54fe655176d3df1a9f94b87c01ed377acaa570682dc5d72c95ef07b",
                          case: :lower
                        )
  @staging_mrenclave Base.decode16!(
                       "6d9b9649fa3a337754a98059c66d48ac77aaca5299d3b27d6ed1e646c7c81c0a",
                       case: :lower
                     )
  @intel_root_public_key Base.decode16!(
                           "040ba9c4c0c0c86193a3fe23d6b02cda10a8bbd4e88e48b4458561a36e705525f567918e2edc88e40d860bd0cc4ee26aacc988e505a953558c453f6b0904ae7394",
                           case: :lower
                         )
  @intel_qe_vendor_id Base.decode16!("939a7233f79c4ca9940a0db3957f0607", case: :lower)

  @quote_signed_bytes 432
  @report_bytes 384
  @max_claims 256
  @max_claim_name 1024
  @max_claim_value 1_048_576

  @type pins :: %{
          mrenclave: binary(),
          root_public_key: <<_::520>>,
          qe_vendor_id: <<_::128>>,
          accepted_advisories: [String.t()],
          minimum_evaluation_data_number: non_neg_integer()
        }

  @type failure ::
          :invalid_message
          | :invalid_mrenclave_pin
          | :invalid_evidence
          | :invalid_endorsements
          | :expired
          | :untrusted_root
          | :invalid_certificate_chain
          | :invalid_collateral_signature
          | :qe_identity_mismatch
          | :invalid_quote_signature
          | :platform_tcb_rejected
          | :claims_mismatch
          | :debug_enclave
          | :mrenclave_mismatch
          | :invalid_claims

  @doc """
  The pinned values of an environment (§5.2): its MRENCLAVE, the Intel SGX
  root CA key, the Intel QE vendor ID, the accepted software-hardening
  advisories, and the minimum TCB evaluation data number.
  """
  @spec pins(:production | :staging) :: pins()
  def pins(environment) do
    %{
      mrenclave: if(environment == :staging, do: @staging_mrenclave, else: @production_mrenclave),
      root_public_key: @intel_root_public_key,
      qe_vendor_id: @intel_qe_vendor_id,
      accepted_advisories: ["INTEL-SA-00615", "INTEL-SA-00657"],
      minimum_evaluation_data_number: 21
    }
  end

  @doc """
  Verifies an attestation message at `now` (Unix seconds). Returns
  `{:ok, %{public_key: <<_::256>>, claims: %{name => value}}}` or
  `{:error, failure}`. `public_key` is the Noise responder static key.
  """
  @spec verify(binary(), pins(), integer()) ::
          {:ok, %{public_key: <<_::256>>, claims: %{String.t() => binary()}}}
          | {:error, failure()}
  def verify(message, pins, now) when is_binary(message) and is_integer(now) do
    t = now + @clock_allowance_s

    with {:ok, evidence_bytes, endorsement_bytes} <- decode_message(message),
         :ok <- check_pin(pins),
         {:ok, evidence} <- parse_evidence(evidence_bytes),
         {:ok, endorsements} <- parse_endorsements(endorsement_bytes),
         :ok <- check_expiry(evidence, endorsements, pins, t),
         {:ok, root} <- check_root(endorsements, pins),
         :ok <- check_chains(evidence, endorsements, root, t),
         :ok <- check_collateral_signatures(endorsements),
         :ok <- check_qe_identity(evidence, endorsements.qe_identity, pins),
         :ok <- check_quote_signatures(evidence),
         :ok <- check_platform_tcb(evidence, endorsements.tcb_info, pins),
         :ok <- check_claims_binding(evidence),
         :ok <- check_not_debug(evidence.report),
         :ok <- check_mrenclave(evidence.report, pins),
         {:ok, public_key} <- check_claims(evidence.claims) do
      {:ok, %{public_key: public_key, claims: evidence.claims}}
    end
  end

  # --- Message (§5.1) ------------------------------------------------------

  defp decode_message(message) do
    wire = __MODULE__.Wire.decode(message)

    cond do
      wire.evidence == "" -> {:error, :invalid_evidence}
      wire.endorsements == "" -> {:error, :invalid_endorsements}
      true -> {:ok, wire.evidence, wire.endorsements}
    end
  rescue
    Protobuf.DecodeError -> {:error, :invalid_message}
  end

  defp check_pin(%{
         mrenclave: <<_::binary-size(32)>>,
         root_public_key: <<4, _::binary-size(64)>>
       }),
       do: :ok

  defp check_pin(_pins), do: {:error, :invalid_mrenclave_pin}

  # --- Evidence (§5.4) -----------------------------------------------------

  defp parse_evidence(bytes) do
    with <<header::binary-size(48), report::binary-size(@report_bytes), rest::binary>> <- bytes,
         <<3::little-16, 2::little-16, _::binary>> <- header,
         <<signature_data_length::little-32, signature_data::binary>> <- rest,
         true <- byte_size(signature_data) >= signature_data_length,
         <<quote_signature::binary-size(64), attestation_key::binary-size(64),
           qe_report::binary-size(@report_bytes), qe_report_signature::binary-size(64),
           auth_length::little-16, qe_auth::binary-size(auth_length), 5::little-16,
           cert_length::little-32, cert_data::binary-size(cert_length), claims_buffer::binary>> <-
           signature_data,
         {:ok, pck_chain} <- X509.pem_chain(cert_data),
         {:ok, claims} <- parse_claims(claims_buffer) do
      {:ok,
       %{
         signed: binary_part(bytes, 0, @quote_signed_bytes),
         qe_vendor_id: binary_part(header, 12, 16),
         report: parse_report(report),
         quote_signature: quote_signature,
         attestation_key: attestation_key,
         qe_report_raw: qe_report,
         qe_report: parse_report(qe_report),
         qe_report_signature: qe_report_signature,
         qe_auth: qe_auth,
         pck_chain: pck_chain,
         claims_buffer: claims_buffer,
         claims: claims
       }}
    else
      _ -> {:error, :invalid_evidence}
    end
  end

  defp parse_report(
         <<cpu_svn::binary-size(16), miscselect::binary-size(4), _::binary-size(12),
           _ext_prod_id::binary-size(16), attributes::binary-size(16), mrenclave::binary-size(32),
           _::binary-size(32), mrsigner::binary-size(32), _::binary-size(32),
           _config_id::binary-size(64), isvprodid::little-16, isvsvn::little-16,
           _config_svn::little-16, _::binary-size(42), _family_id::binary-size(16),
           report_data::binary-size(64)>>
       ) do
    %{
      cpu_svn: cpu_svn,
      miscselect: miscselect,
      attributes: attributes,
      mrenclave: mrenclave,
      mrsigner: mrsigner,
      isvprodid: isvprodid,
      isvsvn: isvsvn,
      report_data: report_data
    }
  end

  defp parse_claims(<<1::little-64, count::little-64, rest::binary>>) when count <= @max_claims,
    do: parse_claim(rest, count, %{})

  defp parse_claims(_buffer), do: :error

  defp parse_claim("", 0, claims), do: {:ok, claims}
  defp parse_claim(_trailing, 0, _claims), do: :error

  # Two claims with the same name (after the trailing 0x00 is removed) are
  # not an error: the later one replaces the earlier one (§5.4, §5.3 step 12).
  defp parse_claim(
         <<name_length::little-64, value_length::little-64, rest::binary>>,
         count,
         claims
       )
       when name_length <= @max_claim_name and value_length <= @max_claim_value do
    with <<name::binary-size(^name_length), value::binary-size(^value_length), rest::binary>> <-
           rest,
         name = strip_nul(name),
         true <- String.valid?(name) do
      parse_claim(rest, count - 1, Map.put(claims, name, value))
    else
      _ -> :error
    end
  end

  defp parse_claim(_rest, _count, _claims), do: :error

  defp strip_nul(bytes) do
    size = byte_size(bytes) - 1

    case bytes do
      <<head::binary-size(^size), 0>> -> head
      _ -> bytes
    end
  end

  # --- Endorsements (§5.5) -------------------------------------------------

  defp parse_endorsements(bytes) do
    with <<1::little-32, 2::little-32, _size::little-32, count::little-32, rest::binary>>
         when count >= 9 <- bytes,
         <<offset_bytes::binary-size(^count * 4), data::binary>> <- rest,
         offsets = for(<<offset::little-32 <- offset_bytes>>, do: offset),
         true <- strictly_increasing?(offsets) and byte_size(data) > List.last(offsets),
         fields = fields(data, offsets),
         [
           <<1::little-32>>,
           tcb_info,
           tcb_chain,
           pck_crl,
           root_crl,
           pck_crl_chain,
           qe_identity,
           qe_chain,
           _creation_time | _
         ] <- fields,
         {:ok, tcb_info} <- Collateral.tcb_info(strip_nul(tcb_info)),
         {:ok, qe_identity} <- Collateral.qe_identity(strip_nul(qe_identity)),
         {:ok, tcb_chain} <- X509.pem_chain(tcb_chain),
         {:ok, pck_crl_chain} <- X509.pem_chain(pck_crl_chain),
         {:ok, qe_chain} <- X509.pem_chain(qe_chain),
         {:ok, pck_crl} <- X509.crl(pck_crl),
         {:ok, root_crl} <- X509.crl(root_crl) do
      {:ok,
       %{
         tcb_info: tcb_info,
         tcb_chain: tcb_chain,
         pck_crl: pck_crl,
         root_crl: root_crl,
         pck_crl_chain: pck_crl_chain,
         qe_identity: qe_identity,
         qe_chain: qe_chain
       }}
    else
      _ -> {:error, :invalid_endorsements}
    end
  end

  defp strictly_increasing?(offsets),
    do: offsets |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a < b end)

  defp fields(data, offsets) do
    ends = tl(offsets) ++ [byte_size(data)]
    for {from, to} <- Enum.zip(offsets, ends), do: binary_part(data, from, to - from)
  end

  # --- Checks (§5.3) -------------------------------------------------------

  # Steps 2 and 3.
  defp check_expiry(evidence, endorsements, pins, t) do
    certs =
      evidence.pck_chain ++
        endorsements.tcb_chain ++ endorsements.qe_chain ++ endorsements.pck_crl_chain

    minimum = pins.minimum_evaluation_data_number

    if Enum.all?(certs, &X509.valid_at?(&1, t)) and
         t < endorsements.pck_crl.next_update and t < endorsements.root_crl.next_update and
         t <= endorsements.tcb_info.next_update and
         endorsements.tcb_info.evaluation_data_number >= minimum and
         t <= endorsements.qe_identity.next_update and
         endorsements.qe_identity.evaluation_data_number >= minimum,
       do: :ok,
       else: {:error, :expired}
  end

  # Step 4.
  defp check_root(endorsements, pins) do
    root = List.last(endorsements.tcb_chain)

    if X509.pinned_root?(root, pins.root_public_key) and
         X509.crl_signed_by?(endorsements.root_crl, pins.root_public_key),
       do: {:ok, root},
       else: {:error, :untrusted_root}
  end

  # Step 5 (§5.3.1): the root from step 4 is the only trust anchor of all
  # four chains; CRLs must be current at `t`.
  defp check_chains(evidence, endorsements, root, t) do
    crls = [endorsements.root_crl, endorsements.pck_crl]

    results = [
      X509.validate_path(endorsements.pck_crl_chain, root, [endorsements.root_crl], t),
      X509.validate_path(endorsements.pck_crl_chain, root, crls, t),
      X509.validate_path(endorsements.tcb_chain, root, crls, t),
      X509.validate_path(evidence.pck_chain, root, crls, t),
      X509.validate_path(endorsements.qe_chain, root, crls, t)
    ]

    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :invalid_certificate_chain}
  end

  # The collateral documents are signed by the leaves of their chains (§5.5).
  defp check_collateral_signatures(endorsements) do
    with {:ok, tcb_key} <- X509.p256_public_key(hd(endorsements.tcb_chain)),
         {:ok, qe_key} <- X509.p256_public_key(hd(endorsements.qe_chain)),
         true <-
           X509.verify_p256(
             endorsements.tcb_info.signed,
             endorsements.tcb_info.signature,
             tcb_key
           ),
         true <-
           X509.verify_p256(
             endorsements.qe_identity.signed,
             endorsements.qe_identity.signature,
             qe_key
           ) do
      :ok
    else
      _ -> {:error, :invalid_collateral_signature}
    end
  end

  # Step 6.
  defp check_qe_identity(evidence, identity, pins) do
    report = evidence.qe_report

    status =
      case Enum.find(identity.levels, &(&1.isvsvn <= report.isvsvn)) do
        nil -> "Revoked"
        level -> level.status
      end

    if evidence.qe_vendor_id == pins.qe_vendor_id and report.mrsigner == identity.mrsigner and
         report.isvprodid == identity.isvprodid and
         masked(report.miscselect, identity.miscselect_mask) == identity.miscselect and
         masked(report.attributes, identity.attributes_mask) == identity.attributes and
         status == "UpToDate",
       do: :ok,
       else: {:error, :qe_identity_mismatch}
  end

  # Bytewise AND of two byte strings of the same length.
  defp masked(value, mask) when byte_size(value) == byte_size(mask) do
    size = bit_size(value)
    <<a::size(^size)>> = value
    <<b::size(^size)>> = mask
    <<Bitwise.band(a, b)::size(size)>>
  end

  # Step 7.
  defp check_quote_signatures(evidence) do
    expected_qe_data =
      :crypto.hash(:sha256, evidence.attestation_key <> evidence.qe_auth) <> <<0::256>>

    with {:ok, pck_key} <- X509.p256_public_key(hd(evidence.pck_chain)),
         true <-
           X509.verify_p256(evidence.qe_report_raw, evidence.qe_report_signature, pck_key),
         true <- evidence.qe_report.report_data == expected_qe_data,
         true <-
           X509.verify_p256(evidence.signed, evidence.quote_signature, evidence.attestation_key) do
      :ok
    else
      _ -> {:error, :invalid_quote_signature}
    end
  end

  # Step 8.
  defp check_platform_tcb(evidence, tcb_info, pins) do
    with {:ok, sgx} <- X509.sgx_extension(hd(evidence.pck_chain)),
         true <- sgx.fmspc == tcb_info.fmspc and sgx.pce_id == tcb_info.pce_id,
         %{} = level <-
           Enum.find(tcb_info.levels, fn level ->
             Enum.zip(sgx.cpu_svn_components, level.components)
             |> Enum.all?(fn {have, need} -> have >= need end) and
               sgx.pce_svn >= level.pce_svn
           end),
         true <- tcb_accepted?(level, pins) do
      :ok
    else
      _ -> {:error, :platform_tcb_rejected}
    end
  end

  defp tcb_accepted?(%{status: "UpToDate"}, _pins), do: true

  defp tcb_accepted?(%{status: "SWHardeningNeeded", advisories: advisories}, pins),
    do: Enum.all?(advisories, &(&1 in pins.accepted_advisories))

  defp tcb_accepted?(_level, _pins), do: false

  # Step 9.
  defp check_claims_binding(evidence) do
    digest = :crypto.hash(:sha256, evidence.claims_buffer)

    if evidence.report.report_data == digest <> <<0::256>> and digest != <<0::256>>,
      do: :ok,
      else: {:error, :claims_mismatch}
  end

  # Step 10: bit 1 (DEBUG) of the little-endian flags in ATTRIBUTES.
  defp check_not_debug(%{attributes: <<flags::little-64, _::binary>>}) do
    if Bitwise.band(flags, 0x2) == 0, do: :ok, else: {:error, :debug_enclave}
  end

  # Step 11.
  defp check_mrenclave(report, pins) do
    if :crypto.hash_equals(report.mrenclave, pins.mrenclave),
      do: :ok,
      else: {:error, :mrenclave_mismatch}
  end

  # Step 12.
  defp check_claims(claims) do
    with <<_::binary-size(32)>> = public_key <- Map.get(claims, "pk"),
         true <- Enum.all?(["config", "minimum_limits"], &protobuf_claim?(claims, &1)) do
      {:ok, public_key}
    else
      _ -> {:error, :invalid_claims}
    end
  end

  defp protobuf_claim?(claims, name) do
    case Map.fetch(claims, name) do
      {:ok, value} ->
        _ = __MODULE__.AnyMessage.decode(value)
        true

      :error ->
        true
    end
  rescue
    Protobuf.DecodeError -> false
  end
end
