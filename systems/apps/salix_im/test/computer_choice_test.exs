defmodule SalixIM.ComputerChoiceTest do
  use ExUnit.Case, async: true

  alias SalixIM.{ComputerChoice, TaskPlacement}

  @macbook %{
    "device_id" => "dev_mbp",
    "station_id" => "aaa",
    "name" => "Peng's MacBook Pro",
    "os" => "darwin"
  }
  @mini %{
    "device_id" => "dev_mini",
    "station_id" => "bbb",
    "name" => "Mac mini (office)",
    "os" => "darwin"
  }
  @pc %{"device_id" => "dev_pc", "station_id" => "ccc", "name" => "DESKTOP-7", "os" => "windows"}
  @two [@macbook, @mini]

  defp user(text), do: %{"actor_type" => "user", "message_id" => text, "content" => text(text)}
  defp text(text), do: [%{"type" => "text", "text" => text}]

  defp decide(computers, aimed, messages),
    do: ComputerChoice.decide(computers, aimed, messages, fn _ -> nil end)

  defp card(id, labels, metadata \\ %{}) do
    %{
      "actor_type" => "agent",
      "message_id" => id,
      "metadata" => metadata,
      "content" => [
        %{
          "type" => "question",
          "prompt" => "Which?",
          "choices" =>
            Enum.map(labels, fn {choice, label} -> %{"id" => choice, "label" => label} end)
        }
      ]
    }
  end

  defp answer(question, choices, other \\ nil) do
    %{
      "actor_type" => "user",
      "message_id" => "answer-" <> question,
      "content" => [
        %{"type" => "text", "text" => "ok"},
        %{
          "type" => "question_answer",
          "question_message_id" => question,
          "choice_ids" => choices,
          "other" => other
        }
      ]
    }
  end

  test "a request that does not distinguish two computers is refused with both named" do
    assert {:error, {:computer_choice_required, @two} = reason} =
             decide(@two, [@macbook], [user("把 still.fail 在我 Mac 上用模拟器跑起来")])

    message = TaskPlacement.message({:runs_on, reason, :salix})
    assert message =~ "question card"
    assert message =~ "Mac mini (office)"
    assert message =~ "station:aaa"
  end

  test "the person's own words name a computer, however loosely" do
    for words <- ["用 mini 跑", "在 MacBook 上跑", "run it on the Mac mini (office)", "station:bbb 上跑"] do
      named = ComputerChoice.named(words, @two)
      assert named != [], words
    end

    assert decide(@two, [@mini], [user("用 mini 跑")]) == :ok
  end

  test "words alone never refuse a Task for being on the wrong computer; the Router asks once" do
    assert {:error, {:computer_choice_required, _}} =
             decide(@two, [@macbook], [user("用 mini 跑")])
  end

  test "an everyday word is not a computer's name" do
    assert decide([@macbook, @pc], [@macbook], [
             user("We need to win this benchmark"),
             user("Use MacBook Pro")
           ]) == :ok
  end

  test "a clause that rules a computer out chooses nothing" do
    tower = %{@pc | "name" => "Windows Tower"}
    words = user("Don't use Windows Tower; use the other computer")

    assert {:error, {:computer_choice_required, _}} =
             decide([@macbook, tower], [@macbook], [words])

    assert {:error, {:computer_choice_required, _}} = decide([@macbook, tower], [tower], [words])
    assert decide([@macbook, tower], [@macbook], [user("not the tower, use macbook")]) == :ok
  end

  test "an operating system names the computer only when it tells them apart" do
    assert ComputerChoice.named("在我 Mac 上跑", [@macbook, @pc]) == [@macbook]
    assert ComputerChoice.named("在我 Mac 上跑", @two) == []
  end

  test "a card's pick outranks older words, and a newer mention of the Task's computer passes" do
    asked = card("q", [{"c1", @macbook["name"]}, {"c2", @mini["name"]}])

    assert {:error, {:computer_choice_other, [@mini]}} =
             decide(@two, [@macbook], [answer("q", ["c2"]), asked, user("用 macbook")])

    assert decide(@two, [@macbook], [user("换成 macbook"), answer("q", ["c2"]), asked]) == :ok
  end

  test "a person's earlier word still counts on a follow-up turn; agents' words do not" do
    agent = %{
      "actor_type" => "agent",
      "message_id" => "a",
      "content" => text("Mac mini (office) 上跑")
    }

    assert decide(@two, [@mini], [user("再跑一次"), agent, user("用 mini")]) == :ok

    assert {:error, {:computer_choice_required, _}} =
             decide(@two, [@mini], [user("再跑一次"), agent])
  end

  test "an answered which-computer card counts by the choice picked" do
    asked = card("q", [{"c1", @macbook["name"]}, {"c2", @mini["name"]}])

    assert decide(@two, [@mini], [answer("q", ["c2"]), asked]) == :ok

    assert {:error, {:computer_choice_other, [@macbook]}} =
             decide(@two, [@mini], [answer("q", ["c1"]), asked])
  end

  test "a which-computer card answered in other words is not asked again" do
    asked = card("q", [{"c1", @macbook["name"]}, {"c2", @mini["name"]}])
    assert decide(@two, [@mini], [answer("q", [], "办公室那台"), asked]) == :ok
  end

  test "a card about something else, or a skipped card, says nothing" do
    other = card("q", [{"c1", "Debug"}, {"c2", "Release"}])

    skipped =
      put_in(answer("q", [])["content"], [
        %{"type" => "question_answer", "question_message_id" => "q", "skipped" => true}
      ])

    assert {:error, {:computer_choice_required, _}} =
             decide(@two, [@mini], [answer("q", ["c1"]), other])

    assert {:error, {:computer_choice_required, _}} = decide(@two, [@mini], [skipped, other])
  end

  test "a local-account card names the computer it is bound to" do
    asked =
      card("q", [{"use_local_account", "用这台电脑的登录"}, {"drive_remotely", "不用"}], %{
        "local_account" => %{"device_id" => "dev_mini", "runtime" => "claude"}
      })

    assert decide(@two, [@mini], [answer("q", ["drive_remotely"]), asked]) == :ok
  end

  test "a card outside the window is read by id" do
    asked = card("old", [{"c1", @macbook["name"]}, {"c2", @mini["name"]}])

    assert ComputerChoice.decide(@two, [@mini], [answer("old", ["c2"])], fn "old" -> asked end) ==
             :ok
  end

  test "a Task aims at the station it names, or a computer whose id its words carry" do
    station = %{"kind" => "station", "device_id" => "dev_mini"}
    assert ComputerChoice.aimed(@two, %{}, station) == [@mini]

    assert ComputerChoice.aimed(@two, %{}, %{"kind" => "station", "device_id" => "vmm"}) == []

    assert ComputerChoice.aimed(@two, %{"content" => "station:bbb"}, %{"kind" => "cloud_vm"}) ==
             []

    assert ComputerChoice.aimed(
             @two,
             %{"content" => "device_id station:aaa，environment station"},
             nil
           ) ==
             [@macbook]

    assert ComputerChoice.aimed(
             @two,
             %{"content" => [%{"type" => "text", "text" => "device_id dev_mini"}]},
             nil
           ) == [@mini]

    assert ComputerChoice.aimed(
             @two,
             %{"title" => "Write an article about Peng's MacBook Pro"},
             nil
           ) ==
             []

    assert ComputerChoice.aimed(@two, %{"content" => "写一篇关于 MacBook 的短文"}, nil) == []
  end
end
