defmodule Comma.DictationTest do
  use SystemsClock.Case, async: false

  setup do
    Comma.AuthChallengeStore.Memory.reset!()
    :ok
  end

  test "a dictation ticket opens one socket for the member it was issued to" do
    assert {:ok, %{"ticket" => ticket, "expires_at" => _}} =
             Comma.Dictation.ticket(%{"id" => "user-dictating"})

    assert {:ok, %{user_id: "user-dictating"}} = Comma.Dictation.redeem(ticket)
    assert {:error, :invalid_ticket} = Comma.Dictation.redeem(ticket)
  end

  test "a ticket of another purpose, or no ticket, opens nothing" do
    {:ok, grant} =
      Comma.Auth.OneTimeCredentials.issue(
        "station_relay",
        %{"user_id" => "user-dictating"},
        60,
        "user-dictating"
      )

    assert {:error, :invalid_ticket} = Comma.Dictation.redeem(grant.id <> "." <> grant.secret)
    assert {:error, :invalid_ticket} = Comma.Dictation.redeem("not-a-ticket")
    assert {:error, :invalid_ticket} = Comma.Dictation.redeem(nil)
  end
end
