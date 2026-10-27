defmodule BridgeForTeams.DailyBriefPeopleTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.DailyBrief.People
  alias BridgeForTeams.DailyBrief.Sources.Slack
  alias BridgeForTeams.Schema.{DailyBriefAlias, DailyBriefMember}

  test "members get their name, others their id, and labels map back only from the table" do
    alice = member("m-alice", "UALICE1", ["Alice Chen"])
    other_alice = member("m-alice2", "UALICE2", ["Alice Chen"])
    people = People.build([alice, other_alice], ["slack:UBOB1", nil, "slack:UALICE1"])

    assert People.label(people, "slack:UALICE1") == "@Alice_Chen"
    assert People.label(people, "slack:UALICE2") == "@Alice_Chen-2"
    assert People.label(people, "slack:UBOB1") == "@UBOB1"

    assert People.resolve(people, "@Alice_Chen-2") == {"slack:UALICE2", "m-alice2"}
    assert People.resolve(people, "UBOB1") == {"slack:UBOB1", nil}
    # A raw Slack mention or a made-up name names nobody.
    assert People.resolve(people, "@Carol") == {nil, nil}
    # A Slack mention the model echoes names the person when the table has them.
    assert People.resolve(people, "<@UALICE1>") == {"slack:UALICE1", "m-alice"}
    assert People.resolve(people, "<@UCAROL1>") == {nil, nil}

    # An alias that is only punctuation falls back to the id.
    assert People.label(People.build([member("m-x", "UX1", ["@ <>"])], []), "slack:UX1") == "@UX1"

    assert Slack.label_text("<@UALICE1> and <@UBOB1|bob>, ping <@UCAROL1>", people) ==
             "@Alice_Chen and @UBOB1, ping <@UCAROL1>"
  end

  test "someone who is not a member is labelled by the name Slack shows for them" do
    people =
      People.build([], ["slack:UHAOWEN1", "slack:UNONAME1"], %{"slack:UHAOWEN1" => "Haowen Sun"})

    assert People.label(people, "slack:UHAOWEN1") == "@Haowen_Sun"
    assert People.label(people, "slack:UNONAME1") == "@UNONAME1"
    assert People.resolve(people, "@Haowen_Sun") == {"slack:UHAOWEN1", nil}
  end

  defp member(id, slack_id, names) do
    %DailyBriefMember{
      id: id,
      slack_user_id: slack_id,
      aliases: Enum.map(names, &%DailyBriefAlias{term: &1, kind: "name"})
    }
  end
end
