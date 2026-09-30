defmodule SalixSignalProto.ProfileAttachmentOracleTest do
  # Level 2 differential tests of layer C6 (CRS-08, CRS-10) against the
  # oracle's function mode (ORACLE_INTERFACE.md sections 6.4, 6.11 and 6.13),
  # on the same random inputs. Run with `--include signal_oracle` and
  # COMMA_SIGNAL_ORACLE=host:port.
  #
  # The oracle has no attachment or profile-field encryption operation
  # (ORACLE_INTERFACE.md section 7); those checks build the expected bytes
  # from the oracle's AES and HMAC operations with the same keys and nonces.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias SalixSignalProto.{Attachment, Profile}
  alias SalixSignalProto.Attachment.IncrementalMac
  alias SalixSignalProto.Test.Oracle

  @moduletag :signal_oracle

  setup_all do
    {:ok, oracle: Oracle.connect!()}
  end

  defp uuid_string(
         <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
           e::binary-size(6)>>
       ) do
    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end

  describe "profile key (CRS-08 section 3)" do
    property "access key and version match", %{oracle: oracle} do
      check all(profile_key <- binary(length: 32), aci <- binary(length: 16), max_runs: 50) do
        result =
          Oracle.call!(oracle, "zk.profile_key_derive", %{
            profile_key: profile_key,
            aci: {:text, uuid_string(aci)}
          })

        assert Oracle.unhex(result["access_key"]) == Profile.access_key(profile_key)
        assert result["version"] == Profile.version(profile_key, aci)
      end
    end

    property "encrypted fields match AES-256-GCM of the padded plaintext", %{oracle: oracle} do
      check all(
              profile_key <- binary(length: 32),
              nonce <- binary(length: 12),
              about <- string(:alphanumeric, max_length: 512),
              max_runs: 30
            ) do
        {:ok, padded} = Profile.pad(:about, about)
        {:ok, encrypted} = Profile.encrypt_about(profile_key, about, nonce)

        expected =
          Oracle.call!(oracle, "aes256gcm.encrypt", %{
            key: profile_key,
            nonce: nonce,
            plaintext: padded
          })

        assert encrypted == nonce <> Oracle.unhex(expected["ciphertext"])
      end
    end
  end

  describe "attachment encryption (CRS-10 section 6)" do
    property "the blob is IV, the oracle's AES-CBC ciphertext and its HMAC", %{oracle: oracle} do
      check all(
              plaintext <- binary(max_length: 2000),
              keys <- binary(length: 64),
              iv <- binary(length: 16),
              max_runs: 30
            ) do
        <<aes_key::binary-size(32), mac_key::binary-size(32)>> = keys
        size = byte_size(plaintext)
        padded = plaintext <> :binary.copy(<<0>>, Attachment.padded_size(size) - size)

        ciphertext =
          Oracle.call!(oracle, "aes256cbc.encrypt", %{key: aes_key, iv: iv, plaintext: padded})
          |> Map.fetch!("ciphertext")
          |> Oracle.unhex()

        mac =
          Oracle.call!(oracle, "hmac.sha256", %{key: mac_key, data: iv <> ciphertext})
          |> Map.fetch!("mac")
          |> Oracle.unhex()

        blob = iv <> ciphertext <> mac
        digest = Oracle.call!(oracle, "hash.sha256", %{data: blob})["digest"]

        assert Attachment.encrypt(plaintext, keys, iv) ==
                 %{blob: blob, digest: Oracle.unhex(digest), size: size}
      end
    end
  end

  describe "incremental MAC (CRS-10 section 9)" do
    property "chunk sizes match", %{oracle: oracle} do
      check all(
              size <-
                one_of([
                  integer(0..100_000_000),
                  integer(16_777_000..16_777_300),
                  integer(536_870_800..536_871_000)
                ]),
              max_runs: 60
            ) do
        assert Oracle.call!(oracle, "attachment.incremental_mac_chunk_size", %{data_size: size}) ==
                 %{"chunk_size" => IncrementalMac.chunk_size(size)}
      end
    end

    property "MACs match for any chunk size and feed size", %{oracle: oracle} do
      check all(
              key <- binary(length: 32),
              data <- binary(max_length: 400),
              chunk_size <- integer(1..70),
              feed_size <- integer(1..50),
              max_runs: 60
            ) do
        result =
          Oracle.call!(oracle, "attachment.incremental_mac", %{
            key: key,
            data: data,
            chunk_size: chunk_size,
            feed_size: feed_size
          })

        assert Oracle.unhex(result["digest"]) == IncrementalMac.compute(key, data, chunk_size)
      end
    end

    property "validation accepts and rejects the same streams", %{oracle: oracle} do
      check all(
              key <- binary(length: 32),
              data <- binary(min_length: 1, max_length: 300),
              chunk_size <- integer(1..64),
              mutation <- member_of([:none, :flip_data, :flip_mac, :truncate, :extend, :chunk]),
              flip_at <- integer(0..10_000),
              max_runs: 80
            ) do
        macs = IncrementalMac.compute(key, data, chunk_size)
        {data, macs, chunk_size} = mutate(mutation, data, macs, chunk_size, flip_at)

        oracle_valid =
          case Oracle.call(oracle, "attachment.incremental_mac_verify", %{
                 key: key,
                 data: data,
                 chunk_size: chunk_size,
                 digest: macs
               }) do
            {:ok, %{"valid" => valid}} -> valid
            {:error, _} -> false
          end

        assert oracle_valid == (IncrementalMac.verify(key, data, chunk_size, macs) == :ok),
               "mutation #{mutation}"
      end
    end
  end

  defp mutate(:none, data, macs, chunk, _at), do: {data, macs, chunk}
  defp mutate(:flip_data, data, macs, chunk, at), do: {flip(data, at), macs, chunk}
  defp mutate(:flip_mac, data, macs, chunk, at), do: {data, flip(macs, at), chunk}

  defp mutate(:truncate, data, macs, chunk, at),
    do: {binary_part(data, 0, rem(at, byte_size(data))), macs, chunk}

  defp mutate(:extend, data, macs, chunk, at), do: {data <> <<at &&& 0xFF>>, macs, chunk}
  defp mutate(:chunk, data, macs, chunk, at), do: {data, macs, chunk + 1 + rem(at, 5)}

  defp flip(binary, at) do
    at = rem(at, byte_size(binary))
    <<head::binary-size(^at), byte, rest::binary>> = binary
    head <> <<bxor(byte, 1)>> <> rest
  end
end
