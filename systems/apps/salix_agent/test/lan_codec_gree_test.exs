defmodule SalixAgent.LanCodec.GreeTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.LanCodec.Gree
  alias SalixAgent.TestSupport.FakeGreeUnit

  @mac "f4911e7aca59"
  @key "Qx7pLm2Zc9Vb4NtK"

  # Packs produced by greeclimate's cipher.py (CipherV1 and CipherV2) for the
  # device replies below, so reading them proves both ciphers against it.
  @scan_ecb "gSoGwqIM2nQgxTqjg6mOsDYTa4hdMuh/bBITRDNv7u9TPPR/T0nC0AF6eKvxQE6b047j2v4fDKtZTQ2mEIDD/t8ZgkQZwjnLmDZbSA1+3uury4AytdYm9P8zJPc3obUra/2J+AaCJX8L9TRrtcuvJLPdrG7obL8weXnGvRhFh7ds8+PNZS2+h12w+RUnd+2ZcCcLRQKLl2weGh8LoKX66L7V+TYaEnEbEm2qsWk1iB4KDo8YqhnOqbJatZYxx9jms4wXSFL3ScoMBAI4PY4eAOSvfICx+lQfMAn9a6dk6ys1mps/SBhwApP6S3vWrYe6"
  @scan_gcm {"JtoKliwv65S28N6bemsWXstjssMAhBP/MVUxCruIx/3INCFPzwM9aNK19evWD4Ccz7+yUNTuYrJU+JrIJ7yR06PTjU65PBoqfJ4zH7TsNpxU/6ORBpWo2obop5B9rvgIA7zqrHsVV+fHEDX9wAut6DajQD8HnL0yeYTAWK9ehI5rung8T0eoMqe3/xg2Sa3wmeLlUUjOh5z18TDskoEgfnazkHN/3RuC9ZmCJjwiMe05Wb+9wcxmP/lu3+kAoEUJYu+Qsu9p5B2m7lp2NCQ2tS8r0V2DR3II4GxcNF2UWE9huw==",
             "sVgqZbWC9U4+RjgxA1Oa/Q=="}
  @dat_ecb "SJNik8sxMGqnJdHUmM9X4dzp4C4LaAz9cPoYY5vwC45Djv5XILPTp8bGRz8+IIKkUR/L5SEVM4PT7edcCAL1qFKIruiDX7oeXoRR792eVM9GDs8eNxnPsEMq+WFpT/T9"
  @dat_gcm {"r3GR3M7WYyt/HWk82FhKh7wHCruQN6WNq6oO40BRsLZwcdY2ZQyPIqD4gUWkjqj5RI5eqEGN3aP3VuhSsLHhRKVb2VY1DeMyz3hMYDhVqSvwKVdtllRCoQ==",
            "8QX9vNwGGsXth0QH2CugYg=="}

  defp envelope(pack) when is_binary(pack),
    do: Jason.encode!(%{"t" => "pack", "i" => 1, "uid" => 0, "cid" => @mac, "pack" => pack})

  defp envelope({pack, tag}),
    do:
      Jason.encode!(%{
        "t" => "pack",
        "i" => 1,
        "uid" => 0,
        "cid" => @mac,
        "pack" => pack,
        "tag" => tag
      })

  test "reads greeclimate's scan and status replies under both ciphers" do
    for {scan, dat, cipher} <- [{@scan_ecb, @dat_ecb, :ecb}, {@scan_gcm, @dat_gcm, :gcm}] do
      assert {:ok,
              %{
                mac: @mac,
                cipher: ^cipher,
                name: "Living room",
                brand: "gree",
                model: "gree",
                version: "V1.1.13"
              }} = Gree.parse_scan(envelope(scan))

      assert {:ok, %{"Pow" => 1, "SetTem" => 26}} = Gree.parse_reply(envelope(dat), @mac, @key)
    end
  end

  test "a unit reads what this codec sends, under both ciphers" do
    for cipher <- [:ecb, :gcm] do
      unit = FakeGreeUnit.unit(scan: cipher, bind: cipher)

      {reply, unit} = FakeGreeUnit.answer(Gree.scan(), unit)
      assert {:ok, %{mac: @mac, cipher: ^cipher}} = Gree.parse_scan(reply)

      {reply, unit} = FakeGreeUnit.answer(Gree.bind(@mac, cipher), unit)
      assert {:ok, @key} = Gree.parse_bind(reply, @mac)

      {reply, unit} =
        FakeGreeUnit.answer(Gree.command(@mac, @key, cipher, ["Pow", "SetTem"], [1, 24]), unit)

      assert {:ok, %{"Pow" => 1, "SetTem" => 24}} = Gree.parse_reply(reply, @mac, @key)

      {reply, _unit} = FakeGreeUnit.answer(Gree.status(@mac, @key, cipher, ["Pow", "Mod"]), unit)
      assert {:ok, %{"Pow" => 1, "Mod" => 1}} = Gree.parse_reply(reply, @mac, @key)
    end
  end

  test "reads a command reply whose values are in p and whose val is empty" do
    unit = FakeGreeUnit.unit(empty_val: true)
    {reply, _unit} = FakeGreeUnit.answer(Gree.command(@mac, @key, :ecb, ["Pow"], [1]), unit)
    assert {:ok, %{"Pow" => 1}} = Gree.parse_reply(reply, @mac, @key)
  end

  test "refuses replies it cannot trust" do
    {pack, tag} = @dat_gcm
    flipped = Base.encode64(:crypto.exor(Base.decode64!(tag), <<1, 0::120>>))

    for bad <- [
          "",
          "not json",
          ~s({"t":"pack"}),
          envelope("!!!"),
          envelope(Base.encode64("short")),
          # A GCM pack whose tag does not verify.
          envelope({pack, flipped}),
          # Encrypted for another key.
          envelope(@scan_ecb)
        ] do
      assert {:error, :malformed} = Gree.parse_reply(bad, @mac, @key)
      assert {:error, :malformed} = Gree.parse_bind(bad, @mac)
    end

    # A reply from another unit never answers for this one.
    assert {:error, :malformed} = Gree.parse_reply(envelope(@dat_ecb), "000000000000", @key)
    assert {:error, :malformed} = Gree.parse_scan(envelope(@dat_ecb))
  end
end
