defmodule SalixSignalProto.ContactDiscovery.LookupTest do
  # CRS-11 §6 and §7: lookup request and response messages and the
  # enclave's close codes.
  use ExUnit.Case, async: true

  alias SalixSignalProto.ContactDiscovery.Lookup

  @pni <<0::96, 0x0101::32>>
  @aci <<0::96, 0x0202::32>>

  test "E.164 numbers are 8-byte big-endian values of their digits" do
    assert Lookup.encode_e164("+14155550100") == {:ok, Base.decode16!("000000034BBC8D94")}
    assert Lookup.decode_e164(Base.decode16!("000000034BBC8D94")) == "+14155550100"

    for bad <- ["+0", "14155550100", "+1415555010a", "+", "+1234567890123456"] do
      assert Lookup.encode_e164(bad) == {:error, :invalid_number}, bad
    end
  end

  test "a token is sent only with the previous numbers; the acknowledgement is 38 01" do
    token = :binary.copy(<<7>>, 20)

    {:ok, one_off} = Lookup.encode_request(new_numbers: ["+15550100001"], token: token)
    {:ok, plain} = Lookup.encode_request(new_numbers: ["+15550100001"])
    assert one_off == plain

    {:ok, repeat} =
      Lookup.encode_request(
        new_numbers: ["+15550100002"],
        previous_numbers: ["+15550100001"],
        token: token,
        aci_access_keys: [{@aci, :binary.copy(<<1>>, 16)}]
      )

    {:ok, n1} = Lookup.encode_e164("+15550100001")
    {:ok, n2} = Lookup.encode_e164("+15550100002")

    assert repeat ==
             <<0x0A, 32>> <>
               @aci <>
               :binary.copy(<<1>>, 16) <>
               <<0x12, 8>> <> n1 <> <<0x1A, 8>> <> n2 <> <<0x32, 20>> <> token

    assert Lookup.token_ack() == <<0x38, 0x01>>
    assert Lookup.encode_request(new_numbers: ["555"]) == {:error, :invalid_number}
  end

  test "results: not found, PNI only, PNI and ACI; zero numbers are skipped" do
    {:ok, a} = Lookup.encode_e164("+15550100001")
    {:ok, b} = Lookup.encode_e164("+15550100002")
    {:ok, c} = Lookup.encode_e164("+15550100003")

    records =
      a <> <<0::256>> <> b <> @pni <> <<0::128>> <> c <> @pni <> @aci <> <<0::64>> <> @pni <> @aci

    {:ok, first} = Lookup.decode_response(<<0x1A, 3, 1, 2, 3>>)
    assert Lookup.token(first) == {:ok, <<1, 2, 3>>}
    assert Lookup.token(%Lookup.Response{}) == {:error, :missing_token}

    # 160 bytes: length varint a0 01.
    {:ok, final} = Lookup.decode_response(<<0x0A, 0xA0, 0x01>> <> records <> <<0x20, 4>>)
    assert final.permits_used == 4

    assert Lookup.results(final) ==
             {:ok,
              %{
                "+15550100001" => nil,
                "+15550100002" => %{pni: @pni, aci: nil},
                "+15550100003" => %{pni: @pni, aci: @aci}
              }}

    # A later message replaces the records field (protobuf merge).
    {:ok, merged} = Lookup.merge_response(final, <<0x0A, 40>> <> a <> @pni <> <<0::128>>)
    assert Lookup.results(merged) == {:ok, %{"+15550100001" => %{pni: @pni, aci: nil}}}
    assert merged.permits_used == 4

    assert Lookup.results(%Lookup.Response{records: <<0::312>>}) == {:error, :malformed}
    assert Lookup.decode_response(<<0x0A, 5, 1>>) == {:error, :malformed}
  end

  test "close codes" do
    assert Lookup.close(1000, "") == :done
    assert Lookup.close(4003, "bad") == {:error, :invalid_argument}
    assert Lookup.close(4008, ~s({"retry_after": 30})) == {:error, {:rate_limited, 30}}
    assert Lookup.close(4008, "later") == {:error, :protocol_error}
    assert Lookup.close(4013, "") == {:error, {:unavailable, 4013}}
    assert Lookup.close(4014, "") == {:error, {:unavailable, 4014}}
    assert Lookup.close(4101, "") == {:error, :invalid_token}
    assert Lookup.close(1011, "") == {:error, :protocol_error}
  end
end
