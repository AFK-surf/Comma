defmodule SalixMigrate.CutoverTest do
  @moduledoc """
  Dual-running cutover orchestration: the per-agent `migrated` flag in
  `ctl/agents/{id}.json` drives one-way routing (`:salix` vs `:go`), `mark_migrated`
  is an idempotent one-way CAS, and cohort rollout selects unmigrated agents and
  reports progress as they cut over. Against the Fake backend.
  """
  use ExUnit.Case, async: false

  alias SalixMigrate.{Import, Cutover, Cohort}
  alias SalixStore.{S3, Keys}

  @session_id "ses1_0000000000000000001"

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  @export %{
    "tenant" => "acme",
    "template" => "assistant",
    "next_message_id" => 2,
    "sessions" => [
      %{"id" => @session_id, "status" => "idle", "last_ack_message_id" => 0}
    ],
    "messages" => [
      %{"id" => 1, "session_id" => @session_id, "role" => "user", "content" => "hi"}
    ]
  }

  defp agent, do: SalixAgent.TestSupport.new_agent_id()

  describe "routing" do
    test "an imported agent routes to :salix" do
      a = agent()
      assert :ok = import_agent(a, @export)

      assert Cutover.migrated?(a) == true
      assert Cutover.route(a) == :salix
    end

    test "a non-migrated agent routes to :go" do
      # No registry record at all → still owned by the legacy cluster.
      a = agent()
      assert Cutover.migrated?(a) == false
      assert Cutover.route(a) == :go
    end

    test "an explicitly un-migrated registry record routes to :go" do
      a = agent()
      body = Jason.encode!(%{"tenant" => "acme", "migrated" => false})
      {:ok, _} = S3.put(Keys.ctl_agent(a), body)

      assert Cutover.migrated?(a) == false
      assert Cutover.route(a) == :go
    end
  end

  describe "mark_migrated" do
    test "cuts an existing un-migrated record over to :salix" do
      a = agent()

      {:ok, _} =
        S3.put(Keys.ctl_agent(a), Jason.encode!(%{"tenant" => "acme", "migrated" => false}))

      assert Cutover.route(a) == :go

      assert :ok = Cutover.mark_migrated(a)
      assert Cutover.route(a) == :salix

      # original fields are preserved through the CAS
      {:ok, %{body: body}} = S3.get(Keys.ctl_agent(a))
      record = Jason.decode!(body)
      assert record["migrated"] == true
      assert record["tenant"] == "acme"
      assert is_binary(record["migrated_at"])
    end

    test "requires an imported registry record" do
      a = agent()
      assert {:error, :not_found} = S3.get(Keys.ctl_agent(a))

      assert {:error, :not_found} =
               Cutover.mark_migrated(a, tenant: "acme", template: "assistant")

      assert Cutover.route(a) == :go
    end

    test "is idempotent: re-marking an already-migrated agent is a no-op :ok" do
      a = agent()
      assert :ok = import_agent(a, @export)
      assert Cutover.migrated?(a) == true

      {:ok, %{etag: etag_before}} = S3.get(Keys.ctl_agent(a))
      assert :ok = Cutover.mark_migrated(a)
      assert :ok = Cutover.mark_migrated(a)

      # no rewrite happened: the object (hence the ETag) is unchanged
      {:ok, %{etag: etag_after}} = S3.get(Keys.ctl_agent(a))
      assert etag_after == etag_before
      assert Cutover.migrated?(a) == true
    end

    test "is one-way: the flag never flips back to :go" do
      a = agent()
      seed_unmigrated(a)
      assert :ok = Cutover.mark_migrated(a, tenant: "acme")
      assert Cutover.route(a) == :salix

      # repeated marks keep it at :salix
      assert :ok = Cutover.mark_migrated(a)
      assert :ok = Cutover.mark_migrated(a)
      assert Cutover.migrated?(a) == true
      assert Cutover.route(a) == :salix
    end
  end

  describe "cohort rollout" do
    test "selects only unmigrated agents and advances progress as they are marked" do
      ids = for _ <- 1..5, do: agent()
      Enum.each(ids, &seed_unmigrated/1)

      # initially nothing is migrated
      p0 = Cohort.progress(ids)
      assert p0 == %{total: 5, migrated: 0, remaining: 5, errors: 0}

      # next cohort picks unmigrated agents, in order, bounded by :size
      cohort = Cohort.next(ids, size: 2)
      assert cohort == Enum.take(ids, 2)

      # mark the cohort
      assert %{ok: ok, errors: []} = Cohort.mark(cohort)
      assert ok == cohort

      # progress advanced
      p1 = Cohort.progress(ids)
      assert p1.migrated == 2
      assert p1.remaining == 3

      # the next cohort skips the already-migrated agents
      cohort2 = Cohort.next(ids, size: 10)
      assert cohort2 == Enum.drop(ids, 2)
      refute Enum.any?(cohort2, &(&1 in cohort))

      # finish the rollout
      %{ok: _, errors: []} = Cohort.mark(cohort2)
      pf = Cohort.progress(ids)
      assert pf == %{total: 5, migrated: 5, remaining: 0, errors: 0}
      assert Cohort.next(ids) == []
    end

    test "respects a :select predicate" do
      ids = for _ <- 1..4, do: agent()
      [_, b, _, d] = ids

      selected = Cohort.next(ids, select: fn id -> id in [b, d] end)
      assert selected == [b, d]
    end

    test "respects a :select allow-list" do
      ids = for _ <- 1..4, do: agent()
      allow = Enum.take(ids, 2)

      assert Cohort.next(ids, select: allow) == allow
    end

    test "mark is idempotent across re-runs" do
      ids = for _ <- 1..3, do: agent()
      Enum.each(ids, &seed_unmigrated/1)
      assert %{errors: []} = Cohort.mark(ids)
      # second run is a no-op set of :ok marks, flag stays migrated
      assert %{ok: ^ids, errors: []} = Cohort.mark(ids)
      assert Cohort.progress(ids).migrated == 3
    end
  end

  defp import_agent(agent_id, export, opts \\ []) do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    export = export |> Map.put("tenant_id", tenant_id) |> Map.put("group_id", group_id)
    Import.import_agent(agent_id, export, opts)
  end

  defp seed_unmigrated(agent_id) do
    {:ok, _} = S3.put(Keys.ctl_agent(agent_id), Jason.encode!(%{"migrated" => false}))
  end
end
