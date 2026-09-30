defmodule SalixMigrate.RoleMigrationTest do
  @moduledoc """
  ROUTER/WORKER role model carried through migration (the Salix half of the
  `willow-salix-export -role/-control-db` pipeline): `export["role"]` and
  `export["prompts"]` land on the control record, not runtime state. Invalid
  roles are rejected at the import edge with `{:error, :invalid_role}` and
  absent fields default to role `"worker"` / empty prompts.
  """
  use ExUnit.Case, async: false

  alias SalixMigrate.Import
  alias SalixStore.{Agent, Keys, S3}
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionStore
  alias SalixAgent.State

  @session_id "ses1_0000000000000000001"

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  @base_export %{
    "tenant" => "acme",
    "template" => "assistant",
    "next_message_id" => 2,
    "sessions" => [
      %{"id" => @session_id, "status" => "idle", "last_ack_message_id" => 0}
    ],
    "messages" => [
      %{
        "id" => 1,
        "session_id" => @session_id,
        "role" => "user",
        "content" => "hello",
        "source_message_id" => "u1"
      }
    ]
  }

  test "router role and both prompts survive import and a claim", %{agent: a} do
    export =
      @base_export
      |> Map.put("role", "router")
      |> Map.put("prompts", %{
        "system_prompt" => "You are a helpful assistant.",
        "router_system_prompt" => "You are the router for this agent group."
      })

    assert :ok = import_agent(a, export)

    agent = read_agent!(a)
    assert agent["role"] == "router"

    assert Map.take(agent, ["system_prompt", "router_system_prompt"]) == %{
             "system_prompt" => "You are a helpful assistant.",
             "router_system_prompt" => "You are the router for this agent group."
           }

    # the rest of the import is untouched by the role fields
    {:ok, owned} = Agent.claim(a, "node-1", State, steal: true)
    refute Map.has_key?(owned.state, :role)
    refute Map.has_key?(owned.state, :prompts)
    refute Map.has_key?(owned.state, :sessions)

    {:ok, session} = InternalSessionStore.read(a, @session_id)

    assert Enum.map(InternalSession.get(session, :messages), & &1.content) == ["hello"]
  end

  test "explicit worker role with a single prompt survives import", %{agent: a} do
    export =
      @base_export
      |> Map.put("role", "worker")
      |> Map.put("prompts", %{"system_prompt" => "Stay on task."})

    assert :ok = import_agent(a, export)

    agent = read_agent!(a)
    assert agent["role"] == "worker"
    assert agent["system_prompt"] == "Stay on task."
    assert agent["router_system_prompt"] == ""

    {:ok, owned} = Agent.claim(a, "node-1", State, steal: true)
    refute Map.has_key?(owned.state, :prompts)
  end

  test "absent role/prompts default to worker with empty prompts", %{agent: a} do
    refute Map.has_key?(@base_export, "role")
    assert :ok = import_agent(a, @base_export)

    agent = read_agent!(a)
    assert agent["role"] == "worker"
    assert agent["system_prompt"] == ""
    assert agent["router_system_prompt"] == ""
  end

  test "prompts are filtered to the contract keys and string values", %{agent: a} do
    export =
      @base_export
      |> Map.put("role", "router")
      |> Map.put("prompts", %{
        "router_system_prompt" => "Route things.",
        "system_prompt" => nil,
        "unexpected_key" => "dropped"
      })

    assert :ok = import_agent(a, export)

    agent = read_agent!(a)
    assert agent["system_prompt"] == ""
    assert agent["router_system_prompt"] == "Route things."
  end

  test "invalid role is rejected at the import edge, before any write", %{agent: a} do
    assert {:error, :invalid_role} =
             import_agent(a, Map.put(@base_export, "role", "supervisor"))

    assert {:error, :invalid_role} =
             import_agent(a, Map.put(@base_export, "role", "Router"))

    assert {:error, :invalid_role} = import_agent(a, Map.put(@base_export, "role", 42))

    # nothing was written: the create-once head is still free, so a subsequent
    # valid import succeeds (it would be {:error, :exists} had a head landed)
    assert :ok = import_agent(a, Map.put(@base_export, "role", "router"))
  end

  defp read_agent!(agent_id) do
    {:ok, %{body: body}} = S3.get(Keys.ctl_agent(agent_id))
    Jason.decode!(body)
  end

  defp import_agent(agent_id, export, opts \\ []) do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    export =
      export
      |> Map.put("tenant_id", tenant_id)
      |> Map.put("group_id", group_id)
      |> then(fn export ->
        if export["role"] == "router",
          do: Map.put(export, "router_session_id", @session_id),
          else: export
      end)

    Import.import_agent(agent_id, export, opts)
  end
end
