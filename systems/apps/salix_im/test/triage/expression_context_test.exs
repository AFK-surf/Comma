defmodule SalixIM.Triage.ExpressionContextTest do
  use SystemsClock.Case, async: true

  alias SalixIM.Triage.ExpressionContext

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
end
