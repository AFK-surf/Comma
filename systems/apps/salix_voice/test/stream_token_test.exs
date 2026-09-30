defmodule SalixVoice.StreamTokenTest do
  use ExUnit.Case, async: false

  alias SalixVoice.StreamToken

  @claims %{
    "call_id" => "vc_TOKENTEST",
    "connect_id" => "conn_1",
    "group_id" => "grp_1",
    "carrier_call_id" => "CA1"
  }

  setup do
    # verify/2 requires a live call: stand in for its CallActor in :pg.
    holder = spawn(fn -> Process.sleep(:infinity) end)
    :ok = :pg.join(SalixVoice.PG, {:call, @claims["call_id"]}, holder)
    on_exit(fn -> Process.exit(holder, :kill) end)
    :ok
  end

  test "a minted token verifies within 60 s and returns its claims" do
    token = StreamToken.mint(@claims, 1_000)
    assert token =~ ~r/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/
    assert {:ok, claims} = StreamToken.verify(token, 1_060)
    assert Map.take(claims, Map.keys(@claims)) == @claims
    assert claims["exp"] == 1_060
  end

  test "expired, tampered, foreign and unknown-call tokens fail closed" do
    token = StreamToken.mint(@claims, 1_000)
    assert {:error, :expired} = StreamToken.verify(token, 1_061)

    [payload, mac] = String.split(token, ".")

    forged_payload =
      @claims
      |> Map.put("group_id", "grp_other")
      |> Map.put("exp", 9_999)
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert {:error, :invalid_token} = StreamToken.verify(forged_payload <> "." <> mac, 1_000)

    assert {:error, :invalid_token} =
             StreamToken.verify(payload <> "." <> String.reverse(mac), 1_000)

    assert {:error, :invalid_token} = StreamToken.verify("garbage", 1_000)

    other = StreamToken.mint(Map.put(@claims, "call_id", "vc_GONE"), 1_000)
    assert {:error, :call_not_found} = StreamToken.verify(other, 1_000)
  end
end
