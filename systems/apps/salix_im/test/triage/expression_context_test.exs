defmodule SalixIM.Triage.ExpressionContextTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.ExpressionContext

  test "keeps the legacy writer palette order stable" do
    assert ExpressionContext.standard_emojis() ==
             ~w(+1 heart joy tada eyes thinking_face clap pray raised_hands sparkles)

    assert {:ok, social} = ExpressionContext.build("social", {:error, :unavailable})
    assert social["allowed_emojis"] == Enum.sort(ExpressionContext.standard_emojis())
  end

  test "provider failure keeps the standard social fallback without leaking the reason" do
    assert {:ok, context} =
             ExpressionContext.build("social", {:error, "Bearer private-provider-text"})

    assert context == %{
             "schema" => "comma.triage-expression-context.v1",
             "mode" => "social",
             "allow_reactions" => true,
             "allowed_emojis" => Enum.sort(ExpressionContext.standard_emojis()),
             "catalog" => %{
               "status" => "unavailable",
               "complete?" => false,
               "custom_emojis" => []
             },
             "observed_reactions" => [],
             "guidance" =>
               "Use reactions for lightweight acknowledgement. Prefer a fitting workspace custom emoji when its name or observed use makes the meaning clear; do not guess opaque emoji names."
           }

    assert ExpressionContext.valid?(context)
    assert :ok = ExpressionContext.validate_emoji(context, "tada")
    refute inspect(context) =~ "private-provider-text"
  end

  test "an available catalog contributes only strict sorted custom names" do
    catalog = %{
      "party_parrot" => "https://emoji.invalid/party",
      "ship-it" => "alias:ship",
      "eyes" => "https://emoji.invalid/standard-name",
      " Party " => "https://emoji.invalid/space",
      ":colon_wrapped:" => "https://emoji.invalid/colon",
      "UPPERCASE" => "https://emoji.invalid/upper",
      "bad space" => "https://emoji.invalid/bad",
      String.duplicate("x", 65) => "https://emoji.invalid/long",
      42 => "https://emoji.invalid/non-string"
    }

    assert {:ok, context} = ExpressionContext.build("social", {:ok, catalog})

    assert context["catalog"] == %{
             "status" => "available",
             "complete?" => true,
             "custom_emojis" => ["party_parrot", "ship-it"]
           }

    assert context["allowed_emojis"] ==
             Enum.sort(ExpressionContext.standard_emojis() ++ ["party_parrot", "ship-it"])

    assert :ok = ExpressionContext.validate_emoji(context, "party_parrot")

    assert {:error, :emoji_not_allowed} =
             ExpressionContext.validate_emoji(context, "unknown_custom")

    assert {:error, :emoji_not_allowed} =
             ExpressionContext.validate_emoji(context, ":party_parrot:")

    assert ExpressionContext.valid?(context)
  end

  test "social and project modes both expose the workspace emoji palette" do
    catalog = {:ok, %{"party_parrot" => "https://emoji.invalid/party"}}

    assert {:ok, social} = ExpressionContext.build("social", catalog)

    assert {:ok, project} =
             ExpressionContext.build("project", catalog, [
               %{"reactions" => [%{"name" => "party_parrot", "count" => 3}]}
             ])

    assert social["mode"] == "social"
    assert "party_parrot" in social["allowed_emojis"]
    assert "heart" in social["allowed_emojis"]

    assert project["mode"] == "project"
    assert project["allow_reactions"] == true
    assert project["allowed_emojis"] == social["allowed_emojis"]
    assert :ok = ExpressionContext.validate_emoji(project, "party_parrot")
    assert :ok = ExpressionContext.validate_emoji(project, "heart")
    assert :ok = ExpressionContext.validate_emoji(project, "eyes")
    assert project["observed_reactions"] == [%{"emoji" => "party_parrot", "count" => 3}]
    assert ExpressionContext.valid?(social)
    assert ExpressionContext.valid?(project)
  end

  test "presentation names and malformed modes are never interpreted as policy" do
    for invalid <- ["watercooler", "project-alpha", "", nil, :social] do
      assert {:error, :invalid_expression_mode} =
               ExpressionContext.build(invalid, {:error, :unavailable})
    end
  end

  test "oversize and hostile provider data stays credential-free and bounded" do
    valid =
      Map.new(0..299, fn index ->
        name = "custom_" <> String.pad_leading(Integer.to_string(index), 3, "0")
        {name, "https://private.invalid/#{index}?token=provider-secret"}
      end)

    hostile =
      Map.merge(valid, %{
        "" => "provider-secret-empty",
        "two words" => "provider-secret-space",
        String.duplicate("z", 10_000) => "provider-secret-long",
        {:tuple, :key} => "provider-secret-tuple"
      })

    assert {:ok, context} = ExpressionContext.build("social", {:ok, hostile})

    assert context["catalog"]["status"] == "truncated"
    assert context["catalog"]["complete?"] == false
    assert length(context["catalog"]["custom_emojis"]) == 256

    assert context["catalog"]["custom_emojis"] ==
             Enum.map(0..255, fn index ->
               "custom_" <> String.pad_leading(Integer.to_string(index), 3, "0")
             end)

    assert context["allowed_emojis"] == Enum.sort(Enum.uniq(context["allowed_emojis"]))

    assert length(context["allowed_emojis"]) ==
             length(ExpressionContext.standard_emojis()) + 256

    rendered = inspect(context)
    refute rendered =~ "private.invalid"
    refute rendered =~ "provider-secret"
    assert ExpressionContext.valid?(context)
  end

  test "observed reactions aggregate only bounded allowed hints" do
    custom =
      Map.new(0..39, fn index ->
        {"custom_" <> String.pad_leading(Integer.to_string(index), 2, "0"), "ignored"}
      end)

    assert {:ok, context} = ExpressionContext.build("social", {:ok, custom})

    reactions =
      Enum.map(0..39, fn index ->
        %{
          "name" => "custom_" <> String.pad_leading(Integer.to_string(index), 2, "0"),
          "count" => 1
        }
      end) ++
        [
          %{"name" => "custom_00", "count" => 50_000},
          %{"name" => "unknown_custom", "count" => 999},
          %{"name" => "custom_01", "count" => -1},
          %{"name" => ":custom_02:", "count" => 9},
          %{"name" => "custom_03", "count" => "9"}
        ]

    messages =
      [%{"reactions" => reactions}] ++
        Enum.map(1..300, fn _ -> %{"reactions" => [%{"name" => "eyes", "count" => 1}]} end)

    assert {:ok, enriched} = ExpressionContext.with_observed_reactions(context, messages)

    assert length(enriched["observed_reactions"]) == 32

    assert enriched["observed_reactions"] ==
             Enum.sort_by(enriched["observed_reactions"], & &1["emoji"])

    assert %{"emoji" => "custom_00", "count" => 10_000} in enriched["observed_reactions"]
    refute Enum.any?(enriched["observed_reactions"], &(&1["emoji"] == "unknown_custom"))

    assert Enum.all?(enriched["observed_reactions"], fn hint ->
             Map.keys(hint) |> Enum.sort() == ["count", "emoji"] and
               hint["emoji"] in enriched["allowed_emojis"] and hint["count"] in 1..10_000
           end)

    assert ExpressionContext.valid?(enriched)

    refute ExpressionContext.valid?(
             Map.put(enriched, "allowed_emojis", enriched["allowed_emojis"] ++ ["unknown_custom"])
           )
  end
end
