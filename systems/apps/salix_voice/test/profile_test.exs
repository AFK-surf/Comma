defmodule SalixVoice.ProfileTest do
  use ExUnit.Case, async: true

  alias SalixVoice.Profile

  test "the template is one valid decide request with room for evidence" do
    questions = Profile.questions()

    assert SalixAgent.Decide.validate(%{"state" => "evidence", "questions" => questions}) == :ok
    assert byte_size(Jason.encode!(questions)) <= 4 * 1024
    assert Enum.all?(questions, fn {_key, q} -> Map.has_key?(q["criteria"], "unknown") end)
  end

  test "only template options decide a field" do
    answers = %{
      "language" => %{"choice" => "Klingon", "probabilities_bp" => %{"Klingon" => 9_900}},
      "clock" => %{"choice" => "h24", "probabilities_bp" => %{"h24" => 9_900}}
    }

    assert %{lines: [line], language: nil} = Profile.from_answers(answers)
    refute line =~ "Klingon"
  end
end
