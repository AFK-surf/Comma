ExUnit.start()
Code.require_file("core.exs", __DIR__)
Code.require_file("providers.exs", __DIR__)
Code.require_file("d_adapter.exs", __DIR__)

defmodule MailHarnessAbiTest do
  use ExUnit.Case
  @tag timeout: 30_000
  test "real compiler and runtime honor read/decision envelopes, publisher and stored/acked status" do
    rows =
      for choice <- ~w(notify quiet defer),
          do: %{
            "id" => choice,
            "family" => "ABI",
            "expected" => choice,
            "available_actions" => ["view_source"],
            "input" => %{
              "mail" => %{"source" => "mail://same-source", "subject" => choice, "body" => choice},
              "home" => []
            }
          }

    providers = %{
      decide: fn request ->
        {:ok, %{"answers" => %{"attention" => %{"choice" => request["state"]["mail"]["body"]}}},
         %{}}
      end,
      router: fn _ ->
        {{:final, Jason.encode!(%{choice: "notify", title: "Title", body: "Body"}), %{}, %{}},
         %{}}
      end
    }

    elf = MailHarness.DAdapter.prepare(File.read!(Path.join(__DIR__, "abi_probe.c")))
    results = MailHarness.DAdapter.run(elf, rows, providers, %{"decide" => %{}})
    assert Enum.all?(results, & &1.score.passed)
    assert Enum.map(results, &length(&1.stages)) == [2, 1, 1]
    assert hd(results).output["reminder"]["actions"] == ["view_source"]
    assert hd(results).output["reminder"]["source"]["source"] == "mail://same-source"

    # An intentionally broken guest guesses defer without calling Jev. It must
    # fail even when that string equals the expected result.
    source = File.read!(Path.join(__DIR__, "abi_probe.c"))

    source =
      String.replace(
        source,
        "sf_handle decision_reply = sf_host_call(\"decide\", args, 10000);",
        "sf_handle decision_reply = sf_json_object();"
      )

    payload = Jason.encode!(%{answers: %{attention: %{choice: "defer"}}})

    source =
      String.replace(
        source,
        "sf_handle decision = content(decision_reply);",
        "sf_handle decision = sf_json_parse(#{Jason.encode!(payload)}, #{byte_size(payload)});"
      )

    {:ok, %{"state" => "succeeded", "result" => %{"elf" => encoded}}} = CompareD.compile(source)

    [negative] =
      MailHarness.DAdapter.run(Base.decode64!(encoded), [List.last(rows)], providers, %{
        "decide" => %{}
      })

    assert negative.runtime.choice == "defer"
    assert negative.status == "error"
    refute negative.score.passed
  end
end
