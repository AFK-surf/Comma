defmodule SalixSignalProto.ContactDiscovery.AttestationTest do
  # CRS-11 §5: the client accepts the contact discovery enclave only when
  # every attestation check passes. Level 1 uses the CRS-11 vector
  # attestation-rejection.json. No positive vector exists yet (CRS-11 open
  # question 1), so acceptance and each rejection are checked on synthetic
  # attestations from a test PKI (SalixSignalProto.Test.SgxAttestation).
  use ExUnit.Case, async: true

  alias SalixSignalProto.ContactDiscovery.Attestation
  alias SalixSignalProto.Test.{SgxAttestation, Vectors}

  @day 86_400

  test "CRS-11 vector: every structurally invalid attestation message is rejected" do
    vector = Vectors.load!("crs/CRS-11/attestation-rejection.json")
    assert vector["section"] == "CRS-11"

    for %{"inputs" => inputs, "outputs" => %{"result" => "rejected"}} <- vector["cases"] do
      pins = %{Attestation.pins(:production) | mrenclave: Vectors.hex!(inputs["mrenclave"])}

      now = inputs["verification_time_epoch_seconds"]

      assert {:error, _} =
               Attestation.verify(Vectors.hex!(inputs["attestation_message"]), pins, now),
             inputs["case"]
    end
  end

  test "accepts a complete attestation and returns the attested Noise key, not field 1" do
    a = SgxAttestation.build()

    assert {:ok, %{public_key: key, claims: claims}} =
             Attestation.verify(a.message, a.pins, a.now)

    assert key == a.noise_key
    assert claims["pk"] == a.noise_key
    refute key == :binary.copy(<<9>>, 32)
  end

  test "accepts version-2 TCB info and optional config claims that are protobufs" do
    a = SgxAttestation.build(tcb_version: 2)
    assert {:ok, _} = Attestation.verify(a.message, a.pins, a.now)

    key = :crypto.strong_rand_bytes(32)

    a =
      SgxAttestation.build(claims: [{"pk", key}, {"config", <<8, 1>>}, {"minimum_limits\0", ""}])

    assert {:ok, %{public_key: ^key}} = Attestation.verify(a.message, a.pins, a.now)
  end

  test "the pinned values are those of CRS-11 §5.2" do
    pins = Attestation.pins(:production)
    assert Base.encode16(pins.mrenclave, case: :lower) =~ "15637fa1e54fe655"
    assert Base.encode16(Attestation.pins(:staging).mrenclave, case: :lower) =~ "6d9b9649fa3a"
    assert byte_size(pins.root_public_key) == 65
    assert pins.minimum_evaluation_data_number == 21
  end

  test "rejects an enclave other than the pinned build, and a debug enclave" do
    a = SgxAttestation.build()
    pins = %{a.pins | mrenclave: :binary.copy(<<0xA6>>, 32)}
    assert Attestation.verify(a.message, pins, a.now) == {:error, :mrenclave_mismatch}

    a = SgxAttestation.build(attributes: <<0x07, 0::120>>)
    assert Attestation.verify(a.message, a.pins, a.now) == {:error, :debug_enclave}
  end

  test "rejects collateral that does not chain to the pinned root" do
    a = SgxAttestation.build()
    other = SgxAttestation.build()
    pins = %{a.pins | root_public_key: other.pins.root_public_key}
    assert Attestation.verify(a.message, pins, a.now) == {:error, :untrusted_root}

    a = SgxAttestation.build(root_crl_signer: :platform_ca)
    assert Attestation.verify(a.message, a.pins, a.now) == {:error, :untrusted_root}
  end

  test "rejects revoked certificates" do
    for revoke <- [:pck_leaf, :platform_ca] do
      a = SgxAttestation.build(revoke: revoke)

      assert Attestation.verify(a.message, a.pins, a.now) ==
               {:error, :invalid_certificate_chain},
             inspect(revoke)
    end
  end

  test "checks every time limit at now + 24 hours" do
    # Valid now, but not at t = now + 24 h.
    for opts <- [
          [pck_leaf_not_after: SgxAttestation.now() + 3600],
          [crl_next_update: SgxAttestation.now() + @day],
          [tcb_next_update: SgxAttestation.now() + @day - 1],
          [tcb_evaluation: 20]
        ] do
      a = SgxAttestation.build(opts)
      assert Attestation.verify(a.message, a.pins, a.now) == {:error, :expired}, inspect(opts)
    end
  end

  test "rejects bad signatures in the quote and the collateral" do
    for {tamper, error} <- [
          quote_signature: :invalid_quote_signature,
          qe_report_signature: :invalid_quote_signature,
          qe_report_data: :invalid_quote_signature,
          tcb_info_signature: :invalid_collateral_signature,
          qe_identity_signature: :invalid_collateral_signature
        ] do
      a = SgxAttestation.build(tamper: tamper)
      assert Attestation.verify(a.message, a.pins, a.now) == {:error, error}, inspect(tamper)
    end
  end

  test "platform TCB: UpToDate passes, SWHardeningNeeded only with accepted advisories" do
    hardening = fn advisories ->
      [
        tcb_levels: [
          %{
            components: List.duplicate(5, 16),
            pce_svn: 11,
            status: "SWHardeningNeeded",
            advisories: advisories
          }
        ]
      ]
    end

    a = SgxAttestation.build(hardening.(["INTEL-SA-00615", "INTEL-SA-00657"]))
    assert {:ok, _} = Attestation.verify(a.message, a.pins, a.now)

    a = SgxAttestation.build(hardening.(["INTEL-SA-00615", "INTEL-SA-00999"]))
    assert Attestation.verify(a.message, a.pins, a.now) == {:error, :platform_tcb_rejected}

    # The first matching level in document order is OutOfDate.
    a = SgxAttestation.build(cpu_svn_components: List.duplicate(5, 15) ++ [4])
    assert Attestation.verify(a.message, a.pins, a.now) == {:error, :platform_tcb_rejected}

    a = SgxAttestation.build(tcb_fmspc: <<1, 2, 3, 4, 5, 6>>)
    assert Attestation.verify(a.message, a.pins, a.now) == {:error, :platform_tcb_rejected}
  end

  test "quoting enclave identity must match and be up to date" do
    # ISVSVN 7 matches the OutOfDate level; 5 matches no level (Revoked).
    for opts <- [
          [qe_isvsvn: 7],
          [qe_isvsvn: 5],
          [qe_mrsigner: :binary.copy(<<1>>, 32)],
          [qe_vendor_id: :binary.copy(<<2>>, 16)]
        ] do
      a = SgxAttestation.build(opts)
      pins = %{a.pins | qe_vendor_id: :binary.copy(<<0x93>>, 16)}
      assert Attestation.verify(a.message, pins, a.now) == {:error, :qe_identity_mismatch}
    end
  end

  test "the enclave report must bind the claims, which must carry pk" do
    a = SgxAttestation.build(report_data: :binary.copy(<<3>>, 64))
    assert Attestation.verify(a.message, a.pins, a.now) == {:error, :claims_mismatch}

    for claims <- [
          [{"public_key", :crypto.strong_rand_bytes(32)}],
          [{"pk", :crypto.strong_rand_bytes(31)}],
          [{"pk", :crypto.strong_rand_bytes(32)}, {"config", <<0xFF>>}]
        ] do
      a = SgxAttestation.build(claims: claims)
      assert Attestation.verify(a.message, a.pins, a.now) == {:error, :invalid_claims}
    end
  end

  test "a repeated claim name is not an error: the later claim is used" do
    # CRS-11 §5.4 and §5.3 step 12.
    first = :crypto.strong_rand_bytes(32)
    later = :crypto.strong_rand_bytes(32)

    a = SgxAttestation.build(claims: [{"pk", first}, {"pk\0", later}])
    assert {:ok, %{public_key: ^later}} = Attestation.verify(a.message, a.pins, a.now)

    # The later claim decides validity too.
    a = SgxAttestation.build(claims: [{"pk", first}, {"pk", :crypto.strong_rand_bytes(31)}])
    assert Attestation.verify(a.message, a.pins, a.now) == {:error, :invalid_claims}
  end

  test "root copies at the end of the other chains are checked by name, key identifier and validity only" do
    # CRS-11 §5.3.1 "Root copies in the other chains": the copy is not the
    # anchor, so another key is accepted; §5.4 and step 2 or 3 still apply.
    for chain <- [:pck, :qe, :pck_crl] do
      for variant <- [:other_key, :no_key_id, :no_ca] do
        a = SgxAttestation.build(root_copy: variant, root_copy_in: chain)

        assert {:ok, _} = Attestation.verify(a.message, a.pins, a.now),
               inspect({chain, variant})
      end

      for {variant, error} <- [other_key_id: :invalid, no_cert_sign: :invalid, expired: :expired] do
        a = SgxAttestation.build(root_copy: variant, root_copy_in: chain)
        assert {:error, reason} = Attestation.verify(a.message, a.pins, a.now)

        expected =
          case {error, chain} do
            {:expired, _} -> :expired
            {:invalid, :pck} -> :invalid_evidence
            {:invalid, _} -> :invalid_endorsements
          end

        assert reason == expected, inspect({chain, variant})
      end
    end
  end

  test "PEM chains in any order; an extra root copy fits, an extra leaf does not" do
    # CRS-11 §5.4 chain arrangement.
    a = SgxAttestation.build(pck_chain: :extra_root)
    assert {:ok, _} = Attestation.verify(a.message, a.pins, a.now)

    a = SgxAttestation.build(pck_chain: :extra_leaf)
    assert Attestation.verify(a.message, a.pins, a.now) == {:error, :invalid_evidence}
  end

  test "a CRL must be current at t: thisUpdate after t rejects" do
    # CRS-11 §5.3.1 "CRL time": t is now + 24 hours, so a CRL issued up to
    # 24 hours ahead of the local clock is accepted.
    a = SgxAttestation.build(crl_this_update: SgxAttestation.now() + 12 * 3600)
    assert {:ok, _} = Attestation.verify(a.message, a.pins, a.now)

    a = SgxAttestation.build(crl_this_update: SgxAttestation.now() + @day + 1)

    assert Attestation.verify(a.message, a.pins, a.now) ==
             {:error, :invalid_certificate_chain}
  end

  test "structural errors in the evidence and endorsements reject" do
    trailing = SgxAttestation.claims_buffer([{"pk", :binary.copy(<<1>>, 32)}]) <> <<0>>

    for opts <- [
          [claims_buffer: trailing],
          [pck_chain: :missing_root],
          [pck_chain: :extra_cert]
        ] do
      a = SgxAttestation.build(opts)
      assert Attestation.verify(a.message, a.pins, a.now) == {:error, :invalid_evidence}
    end

    a = SgxAttestation.build(crl_extensions: :no_number)
    assert Attestation.verify(a.message, a.pins, a.now) == {:error, :invalid_endorsements}

    a = SgxAttestation.build()
    too_few = SgxAttestation.endorsements([<<1::little-32>>])
    message = SgxAttestation.message("", a.evidence, too_few)
    assert Attestation.verify(message, a.pins, a.now) == {:error, :invalid_endorsements}
  end
end
