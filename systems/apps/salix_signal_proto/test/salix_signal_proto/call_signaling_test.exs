defmodule SalixSignalProto.CallSignalingTest do
  # CRS-12 has no oracle vectors: the oracle has no calling code. The byte
  # strings below are the worked encodings of CRS-12 section 11, which the
  # CRS hand-encoded from its field tables. They check that Comma reads the
  # tables the same way; they are not interoperability evidence (test levels
  # 6 and 7 are).
  use ExUnit.Case, async: true

  alias SalixSignalProto.CallSignaling

  @call_id 0x0123456789ABCDEF
  @key Base.decode16!("a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209",
         case: :lower
       )
  @params %{
    public_key: @key,
    ice_ufrag: "Ab3x",
    ice_pwd: "0123456789abcdefABCDEF+/",
    receive_video_codecs: [:vp8],
    max_bitrate_bps: 2_000_000,
    encode_video_codecs: [:vp8],
    decode_video_codecs: [:vp8]
  }
  @candidate "candidate:1 1 udp 2122260223 192.0.2.10 50000 typ host generation 0"
  @placeholder "candidate:FAKE 1 tcp 0 127.0.0.1 0 typ host"

  defp hex(string), do: string |> String.replace(" ", "") |> Base.decode16!(case: :lower)

  describe "worked encodings (CRS-12 section 11)" do
    test "an offer with audio-only connection parameters, up to the content message" do
      parameters =
        hex(
          "0a20 a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209" <>
            "1204 41623378" <>
            "1a18 303132333435363738396162636465664142434445462b2f" <>
            "2202 0808 2880897a 3202 0808 3a02 0808"
        )

      wrapper = hex("2252") <> parameters
      assert CallSignaling.encode_wrapper(@params) == wrapper
      assert CallSignaling.audio_only_parameters(@params, 2_000_000) == @params

      offer = hex("08ef9bafcdf8acd19101 1800 2254") <> wrapper
      call_message = hex("0a62") <> offer
      encoded = CallSignaling.encode({:offer, %{call_id: @call_id, parameters: @params}})

      assert encoded == call_message
      assert CallSignaling.to_content(encoded) == hex("1a64") <> call_message

      assert {:ok, %{payload: {:offer, offer}, destination_device_id: nil}} =
               CallSignaling.decode(call_message)

      assert offer == %{call_id: @call_id, media_type: :audio, parameters: @params}
    end

    test "an added ICE candidate and a removal" do
      added = hex("1245 0a43") <> @candidate
      assert CallSignaling.encode_candidate({:added, @candidate}) == added
      assert CallSignaling.decode_candidate(added) == {:ok, {:added, @candidate}}

      removal = hex("122d 0a2b") <> @placeholder <> hex("1a0a 0a04c000020a 10d08603")
      assert CallSignaling.encode_candidate({:removed, {{192, 0, 2, 10}, 50_000}}) == removal

      assert CallSignaling.decode_candidate(removal) ==
               {:ok, {:removed, {{192, 0, 2, 10}, 50_000}}}
    end

    test "hangup type 1 for device 2, and busy" do
      hangup = hex("3a0e 08ef9bafcdf8acd19101 1001 1802")
      assert CallSignaling.encode({:hangup, @call_id, :accepted_elsewhere, 2}) == hangup

      assert {:ok, %{payload: {:hangup, @call_id, :accepted_elsewhere, 2}}} =
               CallSignaling.decode(hangup)

      busy = hex("2a0a 08ef9bafcdf8acd19101")
      assert CallSignaling.encode({:busy, @call_id}) == busy
      assert {:ok, %{payload: {:busy, @call_id}}} = CallSignaling.decode(busy)
    end
  end

  describe "decoding" do
    test "a targeted answer with ICE credentials round-trips; a video offer keeps its type" do
      answer =
        CallSignaling.encode({:answer, %{call_id: 7, parameters: @params}},
          destination_device_id: 3
        )

      assert {:ok,
              %{payload: {:answer, %{call_id: 7, parameters: @params}}, destination_device_id: 3}} =
               CallSignaling.decode(answer)

      video =
        CallSignaling.encode({:offer, %{call_id: 9, media_type: :video, parameters: @params}})

      assert {:ok, %{payload: {:offer, %{media_type: :video}}}} = CallSignaling.decode(video)
    end

    test "an offer without field 4 in its wrapper is an unsupported version (section 5.1)" do
      # Offer: call ID 5, opaque = a wrapper with only field 1 (old protocol).
      old_wrapper = <<0x0A, 0x02, "hi">>
      offer = <<0x08, 5, 0x22, byte_size(old_wrapper)>> <> old_wrapper
      message = <<0x0A, byte_size(offer)>> <> offer
      assert CallSignaling.decode(message) == {:error, {:invalid_offer, 5}}
    end

    test "ICE credentials outside the CRS-13 section 3 checks reject the offer" do
      for {ufrag, pwd} <- [
            {"abc", "abcdefghijklmnopqrstuv"},
            {"abcd", "short"},
            {"ab d", "abcdefghijklmnopqrstuv"}
          ] do
        params = %{@params | ice_ufrag: ufrag, ice_pwd: pwd}
        message = CallSignaling.encode({:offer, %{call_id: 8, parameters: params}})
        assert CallSignaling.decode(message) == {:error, {:invalid_offer, 8}}
      end

      # A 4-character ufrag and a 22-character password with "+" and "/"
      # pass (CRS-13 section 3, credential format).
      params = %{@params | ice_ufrag: "a+/b", ice_pwd: "abcdefghij+/abcdefghij"}
      message = CallSignaling.encode({:offer, %{call_id: 8, parameters: params}})
      assert {:ok, %{payload: {:offer, _}}} = CallSignaling.decode(message)
    end

    test "an offer without a call ID or opaque is ignored (section 3.2)" do
      no_opaque = <<0x0A, 0x02, 0x08, 0x05>>
      assert CallSignaling.decode(no_opaque) == {:error, :empty}
    end

    test "several ICE updates take the first call ID and skip updates without opaque" do
      a = CallSignaling.encode_candidate({:added, @candidate})

      updates =
        [<<0x08, 1, 0x2A, byte_size(a)>> <> a, <<0x08, 1>>, <<0x08, 2, 0x2A, byte_size(a)>> <> a]
        |> Enum.map_join(&(<<0x1A, byte_size(&1)>> <> &1))

      assert {:ok, %{payload: {:ice, 1, [{:added, @candidate}, {:added, @candidate}]}}} =
               CallSignaling.decode(updates)
    end

    test "an invalid removal address is skipped; IPv6 removals decode" do
      bad = <<0x1A, 0x06, 0x0A, 0x02, 1, 2, 0x10, 0x01>>
      assert CallSignaling.decode_candidate(bad) == {:error, :invalid_candidate}

      big_port = <<0x1A, 0x09, 0x0A, 0x04, 1, 2, 3, 4, 0x10, 0x80, 0x80, 0x04>>
      assert CallSignaling.decode_candidate(big_port) == {:error, :invalid_candidate}

      ip6 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      opaque = CallSignaling.encode_candidate({:removed, {ip6, 443}})
      assert CallSignaling.decode_candidate(opaque) == {:ok, {:removed, {ip6, 443}}}
    end

    test "a hangup without its type means normal; a zero device means not given" do
      # CRS-12 section 3.6 lets a receiver read a missing type as 0 (as
      # Desktop and iOS do) or drop the hangup (as Android does); Comma reads 0.
      assert {:ok, %{payload: {:hangup, 3, :normal, nil}}} =
               CallSignaling.decode(<<0x3A, 0x04, 0x08, 0x03, 0x18, 0x00>>)
    end

    test "a sent hangup always carries its type, also type 0" do
      # CRS-12 section 3.6 and CRS-05 section 6.3 row 7: a sender MUST encode
      # field 2; Android peers drop a hangup without it. Call ID 5, type 0 and
      # no device encode as 3a 04 08 05 10 00.
      assert CallSignaling.encode({:hangup, 5, :normal, nil}) == hex("3a04 0805 1000")
      assert CallSignaling.encode({:hangup, 5, 0, nil}) == hex("3a04 0805 1000")
    end

    test "a zero destination device is a broadcast; an opaque without data is dropped" do
      assert {:ok, %{destination_device_id: nil}} =
               CallSignaling.decode(<<0x2A, 0x02, 0x08, 0x01, 0x48, 0x00>>)

      assert CallSignaling.decode(<<0x52, 0x02, 0x10, 0x01>>) == {:error, :empty}

      assert {:ok, %{payload: {:opaque, "x", :immediate}}} =
               CallSignaling.decode(CallSignaling.encode({:opaque, "x", :immediate}))
    end

    test "bytes that are not a call message are malformed" do
      assert CallSignaling.decode(<<0x0A, 0x05, 0x01>>) == {:error, :malformed}
    end
  end

  describe "rules" do
    test "the destination filter (section 3.1)" do
      assert CallSignaling.for_device?(%{destination_device_id: nil}, 1)
      assert CallSignaling.for_device?(%{destination_device_id: 1}, 1)
      refute CallSignaling.for_device?(%{destination_device_id: 2}, 1)
    end

    test "message age and offer expiry (sections 6.1 and 10)" do
      assert CallSignaling.message_age(1_000_000 + 60_999, 1_000_000) == 60
      refute CallSignaling.offer_expired?(60)
      assert CallSignaling.message_age(1_000_000 + 61_000, 1_000_000) == 61
      assert CallSignaling.offer_expired?(61)
      assert CallSignaling.message_age(nil, 5) == 0
      assert CallSignaling.message_age(5, 5) == 0
    end

    test "collisions (section 8)" do
      assert CallSignaling.classify_offer(nil, 1, 1) == :ring

      connected = %{call_id: 10, connected_device: 1, connected_and_accepted: true}
      assert CallSignaling.classify_offer(connected, 20, 1) == :recall
      assert CallSignaling.classify_offer(connected, 20, 2) == :busy

      ringing = %{call_id: 10, connected_device: nil, connected_and_accepted: false}
      assert CallSignaling.classify_offer(ringing, 5, 1) == :ignore
      assert CallSignaling.classify_offer(ringing, 20, 1) == :replace
      assert CallSignaling.classify_offer(ringing, 10, 1) == :both_lose

      # Call IDs compare as unsigned 64-bit integers.
      assert CallSignaling.glare(0xFFFFFFFFFFFFFFFF, 1) == :ignore
    end

    test "caller reactions to callee hangups and busy (sections 7.3 and 8)" do
      ringing = %{accepted: false, connected_device: nil}
      accepted = %{accepted: true, connected_device: 1}

      assert CallSignaling.caller_reaction(ringing, {:hangup, :normal, nil}, 2) ==
               {:end, {:hangup, :declined_elsewhere, 2}}

      assert CallSignaling.caller_reaction(ringing, :busy, 3) ==
               {:end, {:hangup, :busy_elsewhere, 3}}

      assert CallSignaling.caller_reaction(ringing, {:hangup, :needs_permission, 0}, 2) ==
               {:end, {:hangup, :needs_permission, 2}}

      assert CallSignaling.caller_reaction(ringing, {:hangup, :accepted_elsewhere, 2}, 2) ==
               :ignore

      assert CallSignaling.caller_reaction(accepted, {:hangup, :normal, nil}, 1) == :end
      assert CallSignaling.caller_reaction(accepted, {:hangup, :normal, nil}, 2) == :ignore
    end

    test "callee reactions to caller hangups (sections 7.1 and 7.3)" do
      assert CallSignaling.callee_reaction(:normal, nil, 2) == :end
      assert CallSignaling.callee_reaction(:accepted_elsewhere, 3, 2) == :end
      assert CallSignaling.callee_reaction(:accepted_elsewhere, 2, 2) == :ignore
      assert CallSignaling.callee_reaction(:needs_permission, 1, 2) == :ignore
    end

    test "urgent flags (section 6)" do
      assert CallSignaling.urgent?({:offer, %{}})
      assert CallSignaling.urgent?({:hangup, 1, :normal, nil})
      assert CallSignaling.urgent?({:opaque, "x", :immediate})
      refute CallSignaling.urgent?({:answer, %{}})
      refute CallSignaling.urgent?({:busy, 1})
      refute CallSignaling.urgent?({:ice, 1, []})
    end
  end
end
