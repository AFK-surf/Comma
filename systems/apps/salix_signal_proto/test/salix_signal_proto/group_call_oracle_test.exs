defmodule SalixSignalProto.GroupCallOracleTest do
  # Level 2 differential tests for CRS-14 sections 6.2, 8.1 and 8.2: Comma's
  # SFU key derivation and frame encryption against the oracle's X25519
  # agreement and standard primitives (HKDF-SHA256, AES-256-CTR,
  # HMAC-SHA256) on the same random inputs. The IV, MAC input, truncation and
  # frame layout are the CRS-14 rules; only the primitive steps are oracle
  # evidence. Run with `--include signal_oracle` and COMMA_SIGNAL_ORACLE set.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.GroupCall
  alias SalixSignalProto.GroupCall.Frame
  alias SalixSignalProto.Test.Oracle

  @moduletag :signal_oracle

  setup_all do
    {:ok, socket: Oracle.connect!()}
  end

  property "the SFU SRTP key material equals the oracle's agreement and HKDF", %{socket: socket} do
    check all(
            client <- binary(length: 32),
            sfu <- binary(length: 32),
            extra <- binary(max_length: 16),
            max_runs: 25
          ) do
      sfu_public = Oracle.call!(socket, "x25519.public_from_private", %{private: sfu})

      shared =
        Oracle.call!(socket, "x25519.agree", %{
          private: client,
          public: Oracle.unhex(sfu_public["public"])
        })

      okm =
        Oracle.call!(socket, "hkdf.sha256", %{
          ikm: Oracle.unhex(shared["shared"]),
          info: GroupCall.srtp_label() <> extra,
          length: 56
        })["okm"]

      assert {:ok, Oracle.unhex(okm)} ==
               GroupCall.okm(client, Oracle.unhex(sfu_public["public_raw"]), extra)
    end
  end

  property "frames equal the oracle's HKDF, AES-256-CTR and HMAC steps", %{socket: socket} do
    check all(
            secret <- binary(length: 32),
            steps <- integer(0..3),
            frame_counter <- integer(1..0xFFFFFFFF),
            plaintext <- binary(max_length: 200),
            max_runs: 25
          ) do
      {counter, advanced} =
        Enum.reduce(1..steps//1, {0, secret}, fn _, {n, s} ->
          {n + 1, hkdf(socket, s, "RingRTC Ratchet")}
        end)

      aes_key = hkdf(socket, advanced, "RingRTC AES Key")
      hmac_key = hkdf(socket, advanced, "RingRTC HMAC Key")
      iv = <<frame_counter::64, 0::64>>

      cipher =
        Oracle.unhex(
          Oracle.call!(socket, "aes256ctr.apply", %{key: aes_key, iv: iv, input: plaintext})[
            "output"
          ]
        )

      mac =
        Oracle.unhex(
          Oracle.call!(socket, "hmac.sha256", %{
            key: hmac_key,
            data: iv <> <<byte_size(cipher)::32>> <> cipher <> <<0::32>>
          })["mac"]
        )

      expected = cipher <> <<counter, frame_counter::32>> <> binary_part(mac, 0, 16)

      assert {^counter, ^advanced} = Frame.advance({0, secret}, steps)
      assert Frame.keys(advanced) == %{aes_key: aes_key, hmac_key: hmac_key}
      assert Frame.encrypt(plaintext, Frame.keys(advanced), counter, frame_counter) == expected
    end
  end

  defp hkdf(socket, ikm, info) do
    Oracle.unhex(Oracle.call!(socket, "hkdf.sha256", %{ikm: ikm, info: info, length: 32})["okm"])
  end
end
