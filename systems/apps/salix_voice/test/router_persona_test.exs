defmodule SalixVoice.RouterPersonaTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentWorkspace, InternalSession, InternalSessionStore}
  alias SalixVoice.RouterPersona

  @voice "vcnx"
  @caller "+15550001111"
  @call "scope|vcnx|@+15550001111"
  @owner_dm "scope|cnx1|@U_A"
  @family "scope|cnx1|C_FAMILY"
  @a "provider_user|cnx1|U_A"
  @caller_p "provider_user|vcnx|+15550001111"

  @audience %{tenant_id: "t", connect_id: @voice, user_id: @caller, requester: @caller_p}

  # The IFC facts seam: reports each request and answers with
  # `:ifc_test_reply`, so a test picks the Group's mode and membership.
  defmodule Facts do
    @moduledoc false

    def resolve(request) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_voice, :test_pid),
        {:ifc_resolve, request}
      )

      # A write the Router makes while the facts are read.
      if write = SystemsRuntime.get_env(:salix_voice, :ifc_test_write), do: write.()

      {:ok, SystemsRuntime.fetch_env!(:salix_voice, :ifc_test_reply)}
    end

    def mode(_tenant_id, _group_id), do: "enforce"
  end

  setup do
    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    router_id = SalixStore.Ids.new_agent_id(group_id)
    %{group_id: group_id, router_id: router_id, tenant_id: tenant_id}
  end

  defp seed!(ctx, agent_attrs, texts) do
    SalixAgent.TestSupport.create_control_agent!(
      ctx.router_id,
      Map.merge(
        %{
          "tenant_id" => ctx.tenant_id,
          "group_id" => ctx.group_id,
          "role" => "router",
          "runtime_config" => %{"kind" => "internal"}
        },
        agent_attrs
      )
    )

    SalixAgent.TestSupport.create_control_group!(ctx.group_id, %{
      "tenant_id" => ctx.tenant_id,
      "router_agent_id" => ctx.router_id
    })

    {:ok, %{"router_session_id" => session_id}} = SalixAgent.Control.get_record(ctx.router_id)

    events =
      texts
      |> Enum.with_index(1)
      |> Enum.map(fn
        {{:user, text}, id} ->
          %{
            "type" => "delivery",
            "from_queue" => true,
            "message_id" => id,
            "role" => "user",
            "content" => text,
            "source_message_id" => "source-#{id}",
            "created_at" => id
          }

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

        {{:assistant, text}, id} ->
          %{"type" => "assistant", "message_id" => id, "content" => text, "created_at" => id}

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
      |> InternalSession.new(session_id, %{"created_at" => 0})
      |> InternalSession.apply_events(events)

    :ok = InternalSessionStore.prepare_seed(ctx.router_id, state)
  end

  test "a call speaks with the Router's name, own instructions, notes and newest texts", ctx do
    seed!(
      ctx,
      %{
        "name" => "Dot",
        "system_prompt" => "Shared Router rules.",
        "router_system_prompt" => "Shared Router rules.\n\nYou are cheerful; call the user boss."
      },
      [{:user, "Book the dentist for Friday."}, {:assistant, "Booked for 3 pm."}]
    )

    {:ok, write} =
      AgentWorkspace.prepare_write(ctx.router_id, "/memory/semantic/user.md", "Lives in Beijing.")

    {:ok, _} = AgentWorkspace.seed_operation(ctx.router_id, "seed-notes", %{}, [write])

    assert {:ok, persona} = RouterPersona.resolve(ctx.group_id, @audience)
    assert persona.name == "Dot"
    # The shared prompt the Router's own instructions start with is not persona.
    assert persona.persona == "You are cheerful; call the user boss."
    assert persona.notes == "Lives in Beijing."

    assert persona.input == [
             %{"role" => "user", "text" => "Book the dentist for Friday."},
             %{"role" => "assistant", "text" => "Booked for 3 pm."}
           ]
  end

  test "a Router nobody named speaks as Comma; history keeps the newest texts in bounds", ctx do
    old = String.duplicate("a", 1_400)

    seed!(
      ctx,
      %{"name" => "Default workspace Router"},
      List.duplicate({:user, old}, 20) ++ [{:assistant, "Newest."}]
    )

    assert {:ok, persona} = RouterPersona.resolve(ctx.group_id, @audience)
    assert persona.name == "Comma"
    assert persona.persona == nil
    assert persona.notes == nil
    assert List.last(persona.input) == %{"role" => "assistant", "text" => "Newest."}
    assert persona.input |> Enum.map(&byte_size(&1["text"])) |> Enum.sum() <= 10 * 1024
    assert length(persona.input) < 21
  end

  test "with IFC on, only what the caller may read reaches the call", ctx do
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, Facts)
    SystemsRuntime.put_env(:salix_voice, :test_pid, SystemsRuntime.Proc.self())

    SystemsRuntime.put_env(:salix_voice, :ifc_test_reply, family_reply())

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod)
      SystemsRuntime.delete_env(:salix_voice, :ifc_test_reply)
      SystemsRuntime.delete_env(:salix_voice, :test_pid)
    end)

    seed!(ctx, %{"name" => "Dot"}, [
      {:user, "My bank PIN is 4321.", [@owner_dm]},
      {:assistant, "Noted the PIN.", [@owner_dm]},
      {:user, "Dinner at grandma's on Sunday.", [@family]},
      {:assistant, "Sunday dinner is on the calendar.", [@family]},
      {:user, "Unlabelled from before the check."}
    ])

    {:ok, write} =
      AgentWorkspace.prepare_write(ctx.router_id, "/memory/semantic/user.md", "Owner's notes.")

    {:ok, _} = AgentWorkspace.seed_operation(ctx.router_id, "seed-notes", %{}, [write])

    assert {:ok, persona} = RouterPersona.resolve(ctx.group_id, @audience)

    # One facts read for the caller's one-to-one on the voice connect.
    assert_received {:ifc_resolve, request}

    assert request["destination"] == %{
             "kind" => "provider_direct",
             "provider" => "voice",
             "connect_id" => @voice,
             "user_id" => @caller
           }

    assert request["requester"] == @caller_p

    assert persona.input == [
             %{"role" => "user", "text" => "Dinner at grandma's on Sunday."},
             %{"role" => "assistant", "text" => "Sunday dinner is on the calendar."}
           ]

    # The notes file carries no label the caller can read.
    assert persona.notes == nil
    assert persona.name == "Dot"
  end

  test "notes rewritten while the facts are read keep the label they were checked with", ctx do
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, Facts)
    SystemsRuntime.put_env(:salix_voice, :test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_voice, :ifc_test_reply, family_reply())

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod)
      SystemsRuntime.delete_env(:salix_voice, :ifc_test_reply)
      SystemsRuntime.delete_env(:salix_voice, :ifc_test_write)
      SystemsRuntime.delete_env(:salix_voice, :test_pid)
    end)

    seed!(ctx, %{"name" => "Dot"}, [])
    write_notes!(ctx, "seed-family", "Sunday dinner at grandma's.", [@family])

    # The Router rewrites the notes with something only the owner may read.
    SystemsRuntime.put_env(:salix_voice, :ifc_test_write, fn ->
      write_notes!(ctx, "rewrite-private", "Bank PIN 4321.", [@owner_dm])
    end)

    assert {:ok, persona} = RouterPersona.resolve(ctx.group_id, @audience)
    assert persona.notes == "Sunday dinner at grandma's."
  end

  # The caller is a member of the family room and not of the owner's DM.
  defp family_reply do
    %{
      "mode" => "enforce",
      "destination" => %{"label" => [@call], "writers" => "any"},
      "scopes" => %{
        @call => %{"kind" => "direct", "within" => "space|vcnx"},
        @owner_dm => %{"kind" => "direct", "within" => "space|cnx1"},
        @family => %{"kind" => "room", "within" => "space|cnx1"}
      },
      "membership" => %{
        @call => %{"members" => [@caller_p], "revision" => 1},
        @owner_dm => %{"members" => [@a], "revision" => 1},
        @family => %{"members" => [@a, @caller_p], "revision" => 1}
      },
      "placements" => %{@a => %{"cnx1" => "internal"}, @caller_p => %{@voice => "internal"}},
      "receipts" => [],
      "policy" => %{},
      "now" => 1_000
    }
  end

  defp write_notes!(ctx, operation, body, label) do
    {:ok, write} = AgentWorkspace.prepare_write(ctx.router_id, "/memory/semantic/user.md", body)
    write = Map.put(write, "ifc_label", label)
    {:ok, _} = AgentWorkspace.seed_operation(ctx.router_id, operation, %{}, [write])
  end

  test "a facts failure leaves out the history and notes", ctx do
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, __MODULE__.FailingFacts)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod) end)

    seed!(ctx, %{"name" => "Dot"}, [{:user, "Hello.", ["public"]}])

    assert {:ok, persona} = RouterPersona.resolve(ctx.group_id, @audience)
    assert persona.input == []
    assert persona.notes == nil
  end

  defmodule FailingFacts do
    @moduledoc false
    def resolve(_request), do: {:error, :unavailable}
    def mode(_tenant_id, _group_id), do: "enforce"
  end

  test "a Group without a Router has no persona", ctx do
    assert {:error, "router_unavailable"} = RouterPersona.resolve(ctx.group_id, @audience)
  end
end
