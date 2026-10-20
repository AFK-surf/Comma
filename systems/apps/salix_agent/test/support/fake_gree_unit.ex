defmodule SalixAgent.TestSupport.FakeGreeUnit do
  @moduledoc """
  The device side of the Gree protocol, written apart from
  `SalixAgent.LanCodec.Gree`: it answers a datagram as an air conditioner
  would. `answer/2` takes the unit and returns `{reply | nil, unit}`.

  A unit is `%{mac, key, scan, bind, state}`: `scan` is the cipher of its scan
  reply and `bind` the only cipher it binds with (some Wi-Fi modules answer
  the scan with ECB and bind with GCM only). With `empty_val`, a command reply
  carries its values in `p` and an empty `val`, as some modules send it.
  """

  @generic %{ecb: "a3K8Bx%2r8Y7#xDh", gcm: "{yxAHAY_Lm6pbC/<"}
  @nonce <<0x54, 0x40, 0x78, 0x44, 0x49, 0x67, 0x5A, 0x51, 0x6C, 0x5E, 0x63, 0x13>>
  @aad "qualcomm-test"

  def unit(overrides \\ %{}) do
    Map.merge(
      %{
        mac: "f4911e7aca59",
        key: "Qx7pLm2Zc9Vb4NtK",
        scan: :ecb,
        bind: :ecb,
        name: "Living room",
        state: %{"Pow" => 0, "Mod" => 1, "SetTem" => 26}
      },
      Map.new(overrides)
    )
  end

  def answer(~s({"t":"scan"}), unit) do
    pack = %{
      "t" => "dev",
      "cid" => unit.mac,
      "mac" => unit.mac,
      "brand" => "gree",
      "model" => "gree",
      "name" => unit.name,
      "ver" => "V1.1.13"
    }

    {seal(pack, unit, @generic[unit.scan], unit.scan), unit}
  end

  def answer(datagram, unit) do
    %{"t" => "pack", "tcid" => tcid, "i" => i} = envelope = Jason.decode!(datagram)
    cipher = if envelope["tag"], do: :gcm, else: :ecb

    cond do
      tcid != unit.mac ->
        {nil, unit}

      i == 1 and cipher == unit.bind ->
        %{"t" => "bind"} = open(envelope, @generic[cipher], cipher)
        pack = %{"t" => "bindok", "mac" => unit.mac, "key" => unit.key, "r" => 200}
        {seal(pack, unit, @generic[cipher], cipher), unit}

      i == 1 ->
        {nil, unit}

      true ->
        request(open(envelope, unit.key, cipher), unit, cipher)
    end
  end

  defp request(%{"t" => "status", "cols" => cols}, unit, cipher) do
    pack = %{
      "t" => "dat",
      "mac" => unit.mac,
      "r" => 200,
      "cols" => cols,
      "dat" => Enum.map(cols, &Map.get(unit.state, &1, 0))
    }

    {seal(pack, unit, unit.key, cipher), unit}
  end

  defp request(%{"t" => "cmd", "opt" => opt, "p" => p}, unit, cipher) do
    unit = %{unit | state: Map.merge(unit.state, Map.new(Enum.zip(opt, p)))}
    val = if unit[:empty_val], do: [], else: p
    pack = %{"t" => "res", "mac" => unit.mac, "r" => 200, "opt" => opt, "p" => p, "val" => val}
    {seal(pack, unit, unit.key, cipher), unit}
  end

  defp seal(pack, unit, key, cipher) do
    Jason.encode!(
      Map.merge(
        %{"t" => "pack", "i" => 0, "uid" => 0, "cid" => unit.mac, "tcid" => "app"},
        encrypt(Jason.encode!(pack), key, cipher)
      )
    )
  end

  defp encrypt(plaintext, key, :ecb) do
    n = 16 - rem(byte_size(plaintext), 16)
    padded = plaintext <> :binary.copy(<<n>>, n)
    %{"pack" => Base.encode64(:crypto.crypto_one_time(:aes_128_ecb, key, padded, true))}
  end

  defp encrypt(plaintext, key, :gcm) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, key, @nonce, plaintext, @aad, true)

    %{"pack" => Base.encode64(ciphertext), "tag" => Base.encode64(tag)}
  end

  defp open(%{"pack" => pack}, key, :ecb) do
    :aes_128_ecb
    |> :crypto.crypto_one_time(key, Base.decode64!(pack), false)
    |> String.replace(~r/[\x01-\x10]+\z/, "")
    |> Jason.decode!()
  end

  defp open(%{"pack" => pack, "tag" => tag}, key, :gcm) do
    :aes_128_gcm
    |> :crypto.crypto_one_time_aead(
      key,
      @nonce,
      Base.decode64!(pack),
      @aad,
      Base.decode64!(tag),
      false
    )
    |> Jason.decode!()
  end
end
