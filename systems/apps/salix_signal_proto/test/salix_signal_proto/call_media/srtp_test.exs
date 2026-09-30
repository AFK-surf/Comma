defmodule SalixSignalProto.CallMedia.SrtpTest do
  use ExUnit.Case, async: true

  alias SalixSignalProto.CallMedia.{Rtp, Srtp}
  alias SalixSignalProto.Test.Vectors

  describe "RFC 7714 AEAD_AES_256_GCM vectors (session keys)" do
    setup do
      v = Vectors.load!("public/rfc7714_aead_aes_256_gcm.json")
      key = Vectors.hex!(v["session_key"])
      salt = Vectors.hex!(v["session_salt"])
      ctx = %Srtp{rtp_key: key, rtp_salt: salt, rtcp_key: key, rtcp_salt: salt}
      {:ok, v: v, ctx: ctx}
    end

    test "section 16.2.1: SRTP encryption", %{v: v, ctx: ctx} do
      plain = Vectors.hex!(v["srtp"]["plain"])
      protected = Vectors.hex!(v["srtp"]["protected"])
      assert {:ok, ^protected, _ctx} = Srtp.protect(ctx, plain)
      assert {:ok, ^plain, _ctx} = Srtp.unprotect(ctx, protected)
    end

    test "section 17.2: SRTCP verification and decryption", %{v: v, ctx: ctx} do
      plain = Vectors.hex!(v["srtcp"]["plain"])
      protected = Vectors.hex!(v["srtcp"]["protected"])
      assert {:ok, ^plain, _ctx} = Srtp.unprotect_rtcp(ctx, protected)
    end
  end

  # Output of libsrtp for the same master key and salt: checks the session key
  # derivation (a 96-bit salt in the 112-bit PRF), the rollover counter at the
  # sequence-number wrap and the SRTCP index numbering.
  describe "libsrtp cross-check (master keys)" do
    setup do
      v = Vectors.load!("public/libsrtp_aead_aes_256_gcm.json")
      ctx = Srtp.new(Vectors.hex!(v["master_key"]), Vectors.hex!(v["master_salt"]))
      {:ok, cases: v["cases"], ctx: ctx}
    end

    test "Comma protects every packet exactly as libsrtp does", %{cases: cases, ctx: ctx} do
      Enum.reduce(cases, ctx, fn c, ctx ->
        plain = Vectors.hex!(c["plain"])
        expected = Vectors.hex!(c["protected"])

        {:ok, protected, ctx} =
          case c["kind"] do
            "rtp" -> Srtp.protect(ctx, plain)
            "rtcp" -> Srtp.protect_rtcp(ctx, plain)
          end

        assert protected == expected
        ctx
      end)
    end

    test "Comma opens libsrtp output across the wrap and rejects replays", %{
      cases: cases,
      ctx: ctx
    } do
      ctx =
        Enum.reduce(cases, ctx, fn c, ctx ->
          plain = Vectors.hex!(c["plain"])
          protected = Vectors.hex!(c["protected"])

          {:ok, ^plain, ctx} =
            case c["kind"] do
              "rtp" -> Srtp.unprotect(ctx, protected)
              "rtcp" -> Srtp.unprotect_rtcp(ctx, protected)
            end

          ctx
        end)

      [first_rtp | _] = for %{"kind" => "rtp"} = c <- cases, do: Vectors.hex!(c["protected"])
      [first_rtcp | _] = for %{"kind" => "rtcp"} = c <- cases, do: Vectors.hex!(c["protected"])
      assert {:error, :replay} = Srtp.unprotect(ctx, first_rtp)
      assert {:error, :replay} = Srtp.unprotect_rtcp(ctx, first_rtcp)
    end
  end

  # Group calls protect the transport to the calling server with
  # AEAD_AES_128_GCM (CRS-14 section 6.2).
  describe "AEAD_AES_128_GCM" do
    test "RFC 7714 section 16.1.1: SRTP encryption with session keys" do
      v = Vectors.load!("public/rfc7714_aead_aes_128_gcm.json")
      key = Vectors.hex!(v["session_key"])
      salt = Vectors.hex!(v["session_salt"])
      ctx = %Srtp{rtp_key: key, rtp_salt: salt, rtcp_key: key, rtcp_salt: salt}
      plain = Vectors.hex!(v["srtp"]["plain"])
      protected = Vectors.hex!(v["srtp"]["protected"])
      assert {:ok, ^protected, _ctx} = Srtp.protect(ctx, plain)
      assert {:ok, ^plain, _ctx} = Srtp.unprotect(ctx, protected)
    end

    test "libsrtp cross-check: master-key derivation, the wrap and SRTCP numbering" do
      v = Vectors.load!("public/libsrtp_aead_aes_128_gcm.json")
      tx = Srtp.new(Vectors.hex!(v["master_key"]), Vectors.hex!(v["master_salt"]))
      rx = Srtp.new(Vectors.hex!(v["master_key"]), Vectors.hex!(v["master_salt"]))

      Enum.reduce(v["cases"], {tx, rx}, fn c, {tx, rx} ->
        plain = Vectors.hex!(c["plain"])
        expected = Vectors.hex!(c["protected"])

        {protect, unprotect} =
          case c["kind"] do
            "rtp" -> {&Srtp.protect/2, &Srtp.unprotect/2}
            "rtcp" -> {&Srtp.protect_rtcp/2, &Srtp.unprotect_rtcp/2}
          end

        {:ok, protected, tx} = protect.(tx, plain)
        assert protected == expected
        {:ok, ^plain, rx} = unprotect.(rx, expected)
        {tx, rx}
      end)
    end
  end

  describe "receive rules" do
    setup do
      key = :crypto.strong_rand_bytes(32)
      salt = :crypto.strong_rand_bytes(12)
      {:ok, tx: Srtp.new(key, salt), rx: Srtp.new(key, salt)}
    end

    test "a tampered packet fails authentication and leaves the replay state unchanged",
         %{tx: tx, rx: rx} do
      {:ok, packet, _tx} = Srtp.protect(tx, rtp(10))
      <<head::binary-12, first, rest::binary>> = packet

      assert {:error, :authentication} =
               Srtp.unprotect(rx, <<head::binary, first + 1, rest::binary>>)

      assert {:ok, _plain, _rx} = Srtp.unprotect(rx, packet)
    end

    # CRS-13 section 5: the replay window is 1024 packets.
    test "reordered packets inside the 1024-packet window open once; older ones are refused", %{
      tx: tx,
      rx: rx
    } do
      {packets, _tx} =
        Enum.map_reduce(1..1_100, tx, fn seq, tx ->
          {:ok, packet, tx} = Srtp.protect(tx, rtp(seq))
          {packet, tx}
        end)

      by_seq = Map.new(Enum.zip(1..1_100, packets))
      {:ok, _, rx} = Srtp.unprotect(rx, by_seq[1_100])
      {:ok, _, rx} = Srtp.unprotect(rx, by_seq[100])
      assert {:error, :replay} = Srtp.unprotect(rx, by_seq[100])
      assert {:error, :replay} = Srtp.unprotect(rx, by_seq[50])
      assert {:ok, _, _rx} = Srtp.unprotect(rx, by_seq[1_099])
    end

    test "a packet from before the first rollover period is refused", %{tx: tx, rx: rx} do
      # Protected with rollover counter 0, like the first packet.
      {:ok, early, _} = Srtp.protect(tx, rtp(65_534))
      {:ok, first, _tx} = Srtp.protect(tx, rtp(5))
      {:ok, _, rx} = Srtp.unprotect(rx, first)
      assert {:error, :replay} = Srtp.unprotect(rx, early)
    end

    # The sender picks the SSRC of every packet it authenticates, so a peer
    # could otherwise add receive state for every SSRC value it invents.
    test "an authenticated sender cannot open more than the bounded number of streams", %{
      tx: tx,
      rx: rx
    } do
      max = Srtp.max_receive_streams()

      {rx, tx} =
        Enum.reduce(1..max, {rx, tx}, fn ssrc, {rx, tx} ->
          {:ok, packet, tx} = Srtp.protect(tx, rtp(1, ssrc))
          {:ok, _plain, rx} = Srtp.unprotect(rx, packet)
          {:ok, rtcp, tx} = Srtp.protect_rtcp(tx, <<0x80, 201, 0, 1, ssrc::32>>)
          {:ok, _plain, rx} = Srtp.unprotect_rtcp(rx, rtcp)
          {rx, tx}
        end)

      {:ok, new_stream, tx} = Srtp.protect(tx, rtp(1, max + 1))
      assert {:error, :too_many_streams} = Srtp.unprotect(rx, new_stream)

      {:ok, new_rtcp, tx} = Srtp.protect_rtcp(tx, <<0x80, 201, 0, 1, max + 1::32>>)
      assert {:error, :too_many_streams} = Srtp.unprotect_rtcp(rx, new_rtcp)

      # Streams that are already known keep working.
      {:ok, known, _tx} = Srtp.protect(tx, rtp(2, 1))
      assert {:ok, _plain, _rx} = Srtp.unprotect(rx, known)
    end

    test "a wrong key never opens a packet", %{tx: tx} do
      other = Srtp.new(:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(12))
      {:ok, packet, tx} = Srtp.protect(tx, rtp(1))
      {:ok, rtcp, _tx} = Srtp.protect_rtcp(tx, <<0x80, 201, 0, 1, 2002::32>>)
      assert {:error, :authentication} = Srtp.unprotect(other, packet)
      assert {:error, :authentication} = Srtp.unprotect_rtcp(other, rtcp)
    end

    test "truncated input is malformed", %{rx: rx} do
      assert {:error, :malformed} = Srtp.unprotect(rx, <<0x80, 102, 0, 1>>)
      assert {:error, :malformed} = Srtp.unprotect(rx, rtp(1))
      assert {:error, :malformed} = Srtp.unprotect_rtcp(rx, <<0x80, 201, 0, 1>>)
    end
  end

  defp rtp(seq, ssrc \\ 1002) do
    Rtp.encode(%Rtp{
      payload_type: 102,
      sequence_number: seq,
      timestamp: seq * 2880,
      ssrc: ssrc,
      payload: <<seq::32>>
    })
  end
end
