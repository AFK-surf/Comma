defmodule SalixAgent.RouterDecisionTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{DecideFixture, InternalSession, InternalSessionStore, RouterDecision}

  @questions %{
    "language" => %{
      "type" => "choice",
      "instructions" => "Which language does the user want?",
      "criteria" => %{"meetings" => "Spanish", "none" => "No evidence"}
    }
  }

  setup do
    DecideFixture.start_provider()
    DecideFixture.put_env(:llm_metering_mod, DecideFixture.Meter)
    DecideFixture.put_env(:event_archive_mod, DecideFixture.Archive)
    DecideFixture.put_env(:decide_test_pid, self())
    DecideFixture.put_env(:decide_test_deny, false)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    router_id = SalixStore.Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(router_id, %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "role" => "router",
      "runtime_config" => %{"kind" => "internal"}
    })

    {:ok, %{"router_session_id" => session_id}} = SalixAgent.Control.get_record(router_id)

    %{group_id: group_id, router_id: router_id, session_id: session_id, tenant_id: tenant_id}
  end

  defp seed!(ctx, messages, group_attrs \\ %{}) do
    SalixAgent.TestSupport.create_control_group!(
      ctx.group_id,
      Map.merge(%{"tenant_id" => ctx.tenant_id, "router_agent_id" => ctx.router_id}, group_attrs)
    )

    events =
      messages
      |> Enum.with_index(1)
      |> Enum.map(fn
        {{:user, text, label}, id} ->
          %{
            "type" => "delivery",
            "from_queue" => true,
            "message_id" => id,
            "role" => "user",
            "content" => text,
            "source_message_id" => "source-#{id}",
            "trusted_origin" => %{"provider" => "internal", "ifc" => %{"label" => label}},
            "created_at" => id
          }

        {{:assistant, text, label}, id} ->
          %{
            "type" => "assistant",
            "message_id" => id,
            "content" => text,
            "ifc" => %{"label" => label},
            "created_at" => id
          }
      end)

    state =
      ctx.router_id
      |> InternalSession.new(ctx.session_id, %{
        "created_at" => 0,
        "billing_context" => %{"billing_account_id" => "voice-account"}
      })
      |> InternalSession.apply_events(events)

    :ok = InternalSessionStore.prepare_seed(ctx.router_id, state)
  end

  defp decide(ctx),
    do:
      RouterDecision.decide(ctx.group_id, "Voice preferences", @questions,
        entrypoint: "voice_profile"
      )

  test "sends the newest user and assistant texts of any source, oldest first", ctx do
    group = "group|#{ctx.group_id}"

    seed!(
      ctx,
      [
        {:user, "Hola, ¿me ayudas con la agenda?", ["conversation|conv-router"]},
        {:assistant, "Claro, aquí está tu agenda.", ["conversation|conv-router"]},
        {:user, "Resumen del canal de Slack", ["scope|slack-connect|C-private"]},
        {:assistant, "Nota del runtime", ["agent_private"]},
        {:user, "Gracias, en español por favor", [group, "tag|legal"]}
      ],
      %{"ifc" => %{"public_egress" => "deny", "sealed_atoms" => [group]}}
    )

    assert {:ok, %{"answers" => %{"language" => %{"choice" => "meetings"}}}} = decide(ctx)

    assert_receive {:decision_request, "/v1/systemone", _auth, request}

    # Labels and the Group IFC policy do not filter the evidence (owner decision).
    assert request["state"] == %{
             "purpose" => "Voice preferences",
             "messages" => [
               %{"role" => "user", "text" => "Hola, ¿me ayudas con la agenda?"},
               %{"role" => "assistant", "text" => "Claro, aquí está tu agenda."},
               %{"role" => "user", "text" => "Resumen del canal de Slack"},
               %{"role" => "assistant", "text" => "Nota del runtime"},
               %{"role" => "user", "text" => "Gracias, en español por favor"}
             ]
           }

    assert request["questions"] == @questions

    assert_receive {:decision_meter_before, meter}
    assert meter.entrypoint == "voice_profile"
    assert meter.actor_type == "system"
    assert meter.salix_agent_id == ctx.router_id
    assert meter.session_id == ctx.session_id
    assert meter.billing_context["billing_account_id"] == "voice-account"
  end

  test "without user or assistant text no provider request is made", ctx do
    seed!(ctx, [{:assistant, "   ", ["conversation|conv-router"]}])

    assert {:error, "no_evidence"} = decide(ctx)
    refute_receive {:decision_request, _, _, _}
    refute_receive {:decision_meter_before, _}
  end

  test "evidence is bounded to the newest messages within the decide limit", ctx do
    group = "group|#{ctx.group_id}"
    long = String.duplicate("é", 2_000)

    seed!(ctx, for(n <- 1..20, do: {:user, "#{n} #{long}", [group]}))

    assert {:ok, _answer} = decide(ctx)
    assert_receive {:decision_request, _path, _auth, request}

    messages = request["state"]["messages"]
    assert byte_size(Jason.encode!(Map.delete(request, "model"))) <= 12 * 1024
    assert length(messages) in 1..12
    assert List.last(messages)["text"] =~ ~r/^20 /

    assert Enum.all?(
             messages,
             &(byte_size(&1["text"]) <= 1_500 and String.ends_with?(&1["text"], "…"))
           )
  end
end
