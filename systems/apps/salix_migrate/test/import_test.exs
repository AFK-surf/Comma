defmodule SalixMigrate.ImportTest do
  @moduledoc """
  Salix-side migration import: an exported agent record materializes
  into S3 state such that a first claim reconstructs the conversation exactly,
  and the `migrated` cutover flag is set. Against the Fake backend.
  """
  use ExUnit.Case, async: false

  alias SalixMigrate.Import
  alias SalixAgent.InternalSession
  alias SalixStore.{Agent, S3, Keys}
  alias SalixAgent.{AgentWorkspace, InternalSessionStore, State}

  @session_id "ses1_0000000000000000001"

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  @export %{
    "tenant" => "acme",
    "template" => "assistant",
    "next_message_id" => 4,
    "sessions" => [
      %{
        "id" => @session_id,
        "status" => "idle",
        "last_ack_message_id" => 3,
        "summary" => "prior chat"
      }
    ],
    "messages" => [
      %{
        "id" => 1,
        "session_id" => @session_id,
        "role" => "user",
        "content" => "hello",
        "source_message_id" => "u1"
      },
      %{
        "id" => 2,
        "session_id" => @session_id,
        "role" => "assistant",
        "content" => "hi there"
      },
      %{
        "id" => 3,
        "session_id" => @session_id,
        "role" => "user",
        "content" => "again",
        "source_message_id" => "u2"
      }
    ],
    "vfs" => %{
      "/notes.txt" => %{"ref" => %{"kind" => "blob", "uuid" => "x"}, "size" => 5, "hash" => "h"}
    }
  }

  test "imports an agent so the internal session store reconstructs the exported conversation", %{
    agent: a
  } do
    assert :ok = import_agent(a, @export)

    # registry flag set
    {:ok, %{body: reg}} = S3.get(Keys.ctl_agent(a))
    assert Jason.decode!(reg)["migrated"] == true
    assert Jason.decode!(reg)["tenant_id"] == SalixStore.Ids.tenant_id_from_agent!(a)

    # The agent root remains only a lease/control shell; runtime transcript is
    # reconstructed from the internal session store.
    {:ok, owned} = Agent.claim(a, "node-1", State, steal: true)
    refute Map.has_key?(owned.state, :sessions)

    {:ok, s} = InternalSessionStore.read(a, @session_id)
    messages = InternalSession.get(s, :messages)
    assert Enum.map(messages, & &1.role) == ["user", "assistant", "user"]
    assert Enum.map(messages, & &1.content) == ["hello", "hi there", "again"]
    assert InternalSession.status(s) == :idle
    assert InternalSession.last_ack_message_id(s) == 3
    assert InternalSession.get(s, :summary) == "prior chat"
    assert InternalSession.next_message_id(s) == 4
    # dedupe index carried over (a re-delivery of u1 is dropped)
    assert MapSet.member?(InternalSession.get(s, :input_dedupe), "u1")
    # workspace manifest carried over outside runtime state
    assert {:ok, vfs} = AgentWorkspace.manifest(a)
    assert vfs["/notes.txt"]["size"] == 5
  end

  test "import carries the provider config through the control template", %{agent: a} do
    export =
      Map.put(@export, "llm", %{
        "model" => "gpt-4o",
        "protocol" => "chat_completions",
        "api_key_env" => "TENANT_B_KEY"
      })

    assert :ok = import_agent(a, export)

    {:ok, owned} = Agent.claim(a, "node-1", State, steal: true)
    refute Map.has_key?(owned.state, :llm)

    {:ok, %{body: agent_body}} = S3.get(Keys.ctl_agent(a))
    agent = Jason.decode!(agent_body)
    assert agent["template_id"] == "assistant"

    {:ok, %{body: template_body}} = S3.get(Keys.ctl_template("assistant"))
    template = Jason.decode!(template_body)
    assert template["model"] == "gpt-4o"
    assert template["provider_config"]["protocol"] == "chat_completions"
    assert template["provider_config"]["api_key_env"] == "TENANT_B_KEY"
  end

  test "import is one-way: re-importing an existing agent is rejected", %{agent: a} do
    assert :ok = import_agent(a, @export)
    assert {:error, :exists} = import_agent(a, @export)
    # force overwrites
    assert :ok = import_agent(a, @export, force: true)
  end

  test "imported agent continues normally: new deliveries append after the watermark", %{agent: a} do
    :ok = import_agent(a, @export)
    {:ok, _owned} = Agent.claim(a, "node-1", State, steal: true)
    {:ok, imported} = InternalSessionStore.read(a, @session_id)

    # New input must enter the pending queue first. Materialization then
    # assigns transcript message ids from the imported watermark.
    {:ok, queued} =
      InternalSessionStore.prepare_commit(
        a,
        @session_id,
        [
          %{
            "type" => "queue_append",
            "session_id" => @session_id,
            "kind" => "user_message",
            "dedupe_key" => "u3",
            "payload" => %{
              "source_message_id" => "u3",
              "content" => "after migration"
            }
          }
        ]
      )

    assert length(InternalSession.get(queued, :messages)) == 3

    assert [%{"queue_id" => 1, "payload" => %{"content" => "after migration"}}] =
             InternalSession.get(queued, :input_queue)

    {events, true, hwm} = InternalSession.materialize_pending_input_events(queued)
    assert hwm == InternalSession.next_message_id(imported)

    {:ok, session} = InternalSessionStore.prepare_commit(a, @session_id, events, hwm: hwm)

    messages = InternalSession.get(session, :messages)
    assert length(messages) == 4
    assert List.last(messages).content == "after migration"
    assert List.last(messages).id == 4
    assert InternalSession.get(session, :queue_ack_id) == 1
    assert InternalSession.next_message_id(session) == 5
  end

  defp import_agent(agent_id, export, opts \\ []) do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    export = export |> Map.put("tenant_id", tenant_id) |> Map.put("group_id", group_id)
    Import.import_agent(agent_id, export, opts)
  end
end
