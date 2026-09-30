ExUnit.start()
Code.require_file(System.get_env("MAIL_HARNESS_CORE") || "core.exs", __DIR__)

defmodule MailHarnessTest do
  use ExUnit.Case, async: true

  defp row,
    do: %{
      "id" => "one",
      "family" => "deadline",
      "expected" => "notify",
      "input" => %{
        "mail" => %{
          "source" => "mail://one",
          "subject" => "Renewal",
          "body" => "Renew $40 by Friday."
        },
        "home" => []
      },
      "available_actions" => ["view_source", "snooze"],
      "required_facts" => [["$40"], ["Friday"]]
    }

  defp answer(choice),
    do:
      {:ok, %{"answers" => %{"attention" => %{"choice" => choice}}},
       %{"usage" => %{"prompt_tokens" => 20, "completion_tokens" => 2}}}

  defp draft,
    do: Jason.encode!(%{choice: "notify", title: "Renewal", body: "Renew $40 by Friday."})

  defp providers,
    do: %{
      decide: fn _ -> answer("notify") end,
      router: fn _ ->
        {{:final, draft(), %{}, %{}}, %{usage: %{"input_tokens" => 30, "output_tokens" => 10}}}
      end
    }

  test "caller accepts all final shapes and preserves authoritative card fields" do
    for reply <- [{:final, draft()}, {:final, draft(), %{}}, {:final, draft(), %{}, %{}}] do
      p = %{providers() | router: fn _ -> {reply, %{}} end}
      r = MailHarness.run("b", row(), p)
      assert r.score.passed

      assert r.output["reminder"]["source"] ==
               Map.take(row()["input"]["mail"], ["source", "subject"])

      assert r.output["reminder"]["actions"] == ["view_source", "snooze"]
    end
  end

  test "A B C have the same card shape" do
    cards = for v <- ~w(a b c), do: MailHarness.run(v, row(), providers()).output["reminder"]
    assert Enum.all?(cards, &(Enum.sort(Map.keys(&1)) == ~w(actions body source title)))
    assert length(Enum.uniq(Enum.map(cards, & &1["source"]))) == 1
  end

  test "provider and contract faults never become quiet or defer" do
    for reply <- [
          {:error, :timeout},
          {:final, "not json"},
          {:final, "[]"},
          {:final, "{}"},
          {:final, Jason.encode!(%{choice: "quiet", title: "hidden", body: ""})}
        ] do
      r = MailHarness.run("c", row(), %{providers() | router: fn _ -> {reply, %{}} end})
      assert r.status == "error" and r.choice == nil and r.output == nil
      refute r.score.passed
    end
  end

  test "model cannot replace source or add actions" do
    for key <- ~w(source actions) do
      text = draft() |> Jason.decode!() |> Map.put(key, "forged") |> Jason.encode!()
      r = MailHarness.run("c", row(), %{providers() | router: fn _ -> {{:final, text}, %{}} end})
      assert r.error.kind == "contract"
    end
  end

  test "B error never consumes Router" do
    p = %{decide: fn _ -> {:error, :timeout} end, router: fn _ -> flunk("unexpected Router") end}
    r = MailHarness.run("b", row(), p)
    assert r.status == "error" and length(r.stages) == 1
  end

  test "quiet and unresolved are distinct missing-reminder outcomes" do
    for choice <- ~w(quiet defer) do
      p = %{decide: fn _ -> answer(choice) end, router: fn _ -> flunk("unexpected Router") end}
      r = MailHarness.run("b", row(), p)
      assert r.choice == choice and r.score.missed_reminder
      assert r.score.false_quiet == (choice == "quiet")
      refute r.score.provider_or_contract_error
    end
  end

  test "provider sees evidence but never the expected answer or fact oracle" do
    original = row()

    p = %{
      providers()
      | decide: fn args ->
          refute Map.has_key?(args["state"], "expected")
          refute Map.has_key?(args["state"], "required_facts")
          refute Map.has_key?(args["state"], "home")
          assert args["state"]["mail"] == original["input"]["mail"]
          answer("notify")
        end
    }

    assert MailHarness.run("b", original, p).score.passed
  end

  test "C bypasses Jev and B-context supplies Home" do
    assert MailHarness.run("c", row(), %{providers() | decide: fn _ -> flunk("C called Jev") end}).score.passed

    r = put_in(row(), ["input", "home"], [%{"text" => "watch this"}])

    p = %{
      providers()
      | decide: fn args ->
          assert(args["state"] == r["input"])
          answer("notify")
        end
    }

    assert MailHarness.run("b_context", r, p).score.passed
  end

  test "correct choice without important facts fails usefulness" do
    p = %{
      providers()
      | router: fn _ ->
          {{:final, Jason.encode!(%{choice: "notify", title: "Reminder", body: "Check mail."})},
           %{}}
        end
    }

    r = MailHarness.run("c", row(), p)
    assert r.score.decision_match and r.score.format_valid
    refute r.score.passed
  end

  test "summary separates false quiet, provider error and unknown usage" do
    good = MailHarness.run("b", row(), providers())
    quiet = MailHarness.run("b", row(), %{providers() | decide: fn _ -> answer("quiet") end})
    bad = MailHarness.run("b", row(), %{providers() | decide: fn _ -> {:error, :timeout} end})
    s = MailHarness.summary([good, quiet, bad])["b"]
    assert s.total == 3 and s.passed == 1 and s.errors == 1
    assert s.false_quiet == 1 and s.missed_reminders == 1
    assert s.usage["jev"].calls == 3 and s.usage["jev"].usage_known_calls == 2
    assert s.usage["router"].calls == 1 and s.cost == nil
  end

  test "duplicate case identity is rejected before any provider call" do
    assert_raise RuntimeError, ~r/duplicate/, fn ->
      MailHarness.validate_corpus!(%{"cases" => [row(), row()]})
    end
  end

  test "Chinese digit equivalents pass while a changed deadline still fails" do
    r = %{row() | "required_facts" => [["三点"]]}

    for {body, expected} <- [{"下午3点补交", true}, {"下午三点补交", true}, {"下午4点补交", false}] do
      p = %{
        providers()
        | router: fn _ ->
            {{:final, Jason.encode!(%{choice: "notify", title: "材料", body: body})}, %{}}
          end
      }

      assert MailHarness.run("c", r, p).score.passed == expected
    end
  end
end
