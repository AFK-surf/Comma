defmodule SalixAgent.LanCodec.MiioTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.LanCodec.Miio

  # Vectors built independently with Python hashlib and `openssl enc
  # -aes-128-cbc`, following python-miio's build_msg (tests/test_protocol.py).
  @zero_token :binary.copy(<<0>>, 16)
  @zero_packet Base.decode16!(
                 "21310030000000000123456700000000DBCFD26369CF65A172B5737CC131F6DE" <>
                   "754865DCE4359D961E1BFEE48E12817E"
               )

  @token Base.decode16!("00112233445566778899AABBCCDDEEFF")
  @get_prop Base.decode16!(
              "21310060000000000A1B2C3D5F0E1D2CE753A182FEE1474D6A2E2B565DA5BE91" <>
                "A5516EC6151955DC2BB2D43E7C84C1833AD6ABD2560C09DE4318B095B7713E23" <>
                "66D4BD383C59BDC6C2B0C6191F43F2F2CAAE6E8E38A8CE4E08268E608A56A78C"
            )

  test "builds python-miio packets byte for byte" do
    assert Miio.build(~s({"id": 123456}), @zero_token, <<0x01, 0x23, 0x45, 0x67>>, 0) ==
             @zero_packet

    request = %{"id" => 1, "method" => "get_prop", "params" => ["power"]}

    assert Miio.encode(request, @token, %{
             device_id: <<0x0A, 0x1B, 0x2C, 0x3D>>,
             stamp: 0x5F0E1D2C
           }) ==
             @get_prop
  end

  test "decrypts and verifies python-miio packets" do
    assert {:ok, %{"id" => 123_456}, %{device_id: <<1, 0x23, 0x45, 0x67>>, stamp: 0}} =
             Miio.decode(@zero_packet, @zero_token)

    assert {:ok, %{"id" => 1, "method" => "get_prop", "params" => ["power"]},
            %{device_id: <<0x0A, 0x1B, 0x2C, 0x3D>>, stamp: 0x5F0E1D2C}} =
             Miio.decode(@get_prop, @token)
  end

  test "a wrong token or a tampered packet fails the checksum" do
    assert {:error, :checksum} = Miio.decode(@get_prop, @zero_token)

    <<head::binary-40, byte, rest::binary>> = @get_prop
    assert {:error, :checksum} = Miio.decode(head <> <<Bitwise.bxor(byte, 1)>> <> rest, @token)
  end

  test "tolerates NUL padding and bytes after it, as devices send" do
    packet = Miio.build(~s({"id": 123456}\x00k), @token, <<0, 0, 0, 1>>, 1)
    assert {:ok, %{"id" => 123_456}, _} = Miio.decode(packet, @token)
  end
end
