defmodule SalixStore.PGAuthorityImportTest do
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixStore"]
  alias SalixStore.{Codec, PGAuthorityImport, Repo, S3}

  defmodule CommitReplyProxy do
    def start(port, owner) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, {_, local_port}} = :inet.sockname(listener)

      pid = spawn_link(__MODULE__, :accept, [listener, port, owner])

      {pid, local_port}
    end

    def accept(listener, port, owner) do
      {:ok, client} = :gen_tcp.accept(listener)
      :gen_tcp.close(listener)
      {:ok, upstream} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: :once])
      :inet.setopts(client, active: :once)
      relay(client, upstream, owner, false, <<>>)
    end

    defp relay(client, upstream, owner, armed, buffered) do
      receive do
        {:arm, caller} ->
          send(caller, :armed)
          relay(client, upstream, owner, true, buffered)

        {:tcp, ^client, bytes} ->
          :ok = :gen_tcp.send(upstream, bytes)
          :inet.setopts(client, active: :once)
          relay(client, upstream, owner, armed, buffered)

        {:tcp, ^upstream, bytes} ->
          case forward(buffered <> bytes, client, armed) do
            :committed ->
              send(owner, :commit_reply_dropped)
              :gen_tcp.close(client)
              :gen_tcp.close(upstream)

            pending ->
              :inet.setopts(upstream, active: :once)
              relay(client, upstream, owner, armed, pending)
          end

        {:tcp_closed, _} ->
          :gen_tcp.close(client)
          :gen_tcp.close(upstream)
      end
    end

    defp forward(<<tag, size::32, rest::binary>> = bytes, client, armed)
         when byte_size(rest) >= size - 4 do
      body_size = size - 4
      <<body::binary-size(^body_size), tail::binary>> = rest

      if armed and tag == ?C and body == "COMMIT\0" do
        :committed
      else
        :ok = :gen_tcp.send(client, binary_part(bytes, 0, size + 1))
        forward(tail, client, armed)
      end
    end

    defp forward(bytes, _, _), do: bytes
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    Repo.query!(
      "DELETE FROM salix_cutover_markers WHERE name IN ('salix_pg_authority_s_v1','g1-import-fact')"
    )

    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous) end)
    :ok
  end

  test "source list, wire bytes and decompression have separate request bounds" do
    {:ok, _} = S3.put("source/a", Codec.encode_snapshot(%{data: String.duplicate("a", 20_000)}))
    {:ok, _} = S3.put("source/b", "body")
    assert {:ok, budget} = PGAuthorityImport.limits(page_size: 1, max_inflated_bytes: 100)

    assert {:ok, %{objects: [%{key: "source/a"}], next: next}} =
             PGAuthorityImport.list_page("source/", nil, budget)

    assert is_binary(next)

    assert {:error, {:snapshot_too_large, "source/a"}} =
             PGAuthorityImport.read_snapshot("source/a", budget)

    assert {:ok, _, spent} =
             PGAuthorityImport.read_binary("source/b", %{budget | remaining_bytes: 4})

    assert spent.remaining_bytes == 0

    assert {:error, {:source_byte_limit, "source/b"}} =
             PGAuthorityImport.read_binary("source/b", spent)
  end

  test "two readers share the transport budget and a paused read releases the next reader" do
    {:ok, _} = S3.put("shared/a", Jason.encode!(%{"value" => "a"}))
    {:ok, _} = S3.put("shared/b", Jason.encode!(%{"value" => "b"}))
    S3.Fake.set_fault({:pause, :get, "shared/a"})

    PGAuthorityImport.with_source_budget(
      fn opts ->
        {:ok, budget} = PGAuthorityImport.limits(opts)

        first =
          SystemsRuntime.Task.async(fn -> PGAuthorityImport.read_json("shared/a", budget) end)

        settle_until(fn -> {:get, "shared/a"} in S3.Fake.read_log() end)

        second =
          SystemsRuntime.Task.async(fn -> PGAuthorityImport.read_json("shared/b", budget) end)

        SystemsClock.settle()
        refute {:get, "shared/b"} in S3.Fake.read_log()
        S3.Fake.release_pause()
        assert {:ok, %{value: %{"value" => "a"}}, _} = settled_await(first)
        assert {:ok, %{value: %{"value" => "b"}}, _} = settled_await(second)
      end,
      io_concurrency: 1
    )
  end

  test "prefetch can read the next source while the first response is paused" do
    {:ok, _} = S3.put("parallel/a", "a")
    {:ok, _} = S3.put("parallel/b", "b")
    S3.Fake.set_fault({:pause, :get, "parallel/a"})

    PGAuthorityImport.with_source_budget(fn opts ->
      {:ok, budget} = PGAuthorityImport.limits(opts)

      task =
        SystemsRuntime.Task.async(fn ->
          PGAuthorityImport.prefetch(["parallel/a", "parallel/b"], budget)
        end)

      settle_until(fn -> {:get, "parallel/b"} in S3.Fake.read_log() end)
      S3.Fake.release_pause()

      assert %{
               prefetched: %{
                 "parallel/a" => {:ok, %{body: "a"}},
                 "parallel/b" => {:ok, %{body: "b"}}
               },
               objects: 2,
               wire_bytes: 2
             } =
               settled_await(task)
    end)
  end

  test "facts and exact continuous progress commit together and reentry does not rerun them" do
    initial = %{cursor: %{"phase" => "agents", "token" => nil}, step: 0}
    next = %{"phase" => "sessions", "token" => nil}

    assert {:ok, position} =
             PGAuthorityImport.commit_page(
               :s,
               initial,
               next,
               fn ->
                 fact!(%{"fact" => "original"})

                 %{rows: locks} =
                   Repo.query!(
                     "SELECT c.relname,l.mode FROM pg_locks l JOIN pg_class c ON c.oid=l.relation WHERE l.pid=pg_backend_pid() AND c.relname IN ('salix_cutover_markers') ORDER BY c.relname,l.mode"
                   )

                 IO.puts("G1_LOCK_SCOPE " <> Jason.encode!(locks))
               end,
               %{objects: 1, bytes: 42}
             )

    assert {:ok, ^position} =
             PGAuthorityImport.commit_page(:s, initial, next, fn ->
               flunk("already committed page reran")
             end)

    changed_scope = %{initial | cursor: %{"phase" => "agents", "scope" => "other"}}

    assert {:error, :stale_import_progress} =
             PGAuthorityImport.commit_page(:s, changed_scope, next, fn ->
               flunk("different source accepted")
             end)

    assert position.stats == %{"objects" => 1, "bytes" => 42}
  end

  test "a conflicting fact rolls back the entire page including the marker" do
    Repo.query!(
      "INSERT INTO salix_cutover_markers(name,completed_at,evidence) VALUES('g1-import-fact',$1,$2)",
      [~U[2026-01-01 00:00:00Z], %{"fact" => "kept"}]
    )

    expected = %{cursor: %{"phase" => "agents"}, step: 0}

    assert {:error, {:import_conflict, _, _}} =
             PGAuthorityImport.commit_page(:s, expected, %{"phase" => "complete"}, fn ->
               fact!(%{"fact" => "different"})
             end)

    assert {:ok, nil} = PGAuthorityImport.state(:s)

    %{rows: [[%{"fact" => "kept"}]]} =
      Repo.query!("SELECT evidence FROM salix_cutover_markers WHERE name='g1-import-fact'")

    assert {:ok, %{step: 1}} =
             PGAuthorityImport.commit_page(:s, expected, %{"phase" => "complete"}, fn ->
               fact!(%{"fact" => "kept"})
             end)
  end

  test "exact batches keep NULL, byte values, duplicate keys and page rollback" do
    Repo.checkout(fn ->
      Repo.query!(
        "CREATE TEMP TABLE rfc53_exact (fact_key text UNIQUE, payload bytea, optional text, data jsonb)"
      )

      try do
        original = %{
          "fact_key" => "kept",
          "payload" => <<0, 255>>,
          "optional" => nil,
          "data" => %{"value" => 1}
        }

        assert {:ok, :ok} =
                 Repo.transaction(fn ->
                   PGAuthorityImport.insert_exact_many!(
                     "rfc53_exact",
                     ["fact_key"],
                     [original, %{original | "data" => %{"value" => 1.0}}]
                   )
                 end)

        expected = %{cursor: %{"phase" => "agents"}, step: 0}
        new = %{original | "fact_key" => "new"}
        changed = %{original | "optional" => "different"}

        assert {:error, {:import_conflict, "rfc53_exact", %{"fact_key" => "kept"}}} =
                 PGAuthorityImport.commit_page(:s, expected, %{"phase" => "complete"}, fn ->
                   PGAuthorityImport.insert_exact_many!(
                     "rfc53_exact",
                     ["fact_key"],
                     [new, changed],
                     max_rows: 1
                   )
                 end)

        assert Repo.query!("SELECT fact_key,payload,optional FROM rfc53_exact").rows == [
                 ["kept", <<0, 255>>, nil]
               ]

        assert {:ok, nil} = PGAuthorityImport.state(:s)

        assert {:error, {:import_conflict, "rfc53_exact", %{"fact_key" => "same"}}} =
                 Repo.transaction(fn ->
                   PGAuthorityImport.insert_exact_many!("rfc53_exact", ["fact_key"], [
                     %{original | "fact_key" => "same"},
                     %{changed | "fact_key" => "same"}
                   ])
                 end)

        assert {:ok, :ok} =
                 Repo.transaction(fn ->
                   PGAuthorityImport.insert_exact_many!("rfc53_exact", ["fact_key"], [
                     original,
                     %{original | "fact_key" => nil},
                     %{original | "fact_key" => nil}
                   ])
                 end)

        assert Repo.query!("SELECT count(*) FROM rfc53_exact").rows == [[3]]
      after
        Repo.query!("DROP TABLE rfc53_exact")
      end
    end)
  end

  test "batch update preserves untouched columns and source ordered repeated keys" do
    Repo.checkout(fn ->
      Repo.query!(
        "CREATE TEMP TABLE rfc53_updates (fact_key text PRIMARY KEY, payload text, kind text)"
      )

      try do
        assert {:ok, :ok} =
                 Repo.transaction(fn ->
                   PGAuthorityImport.insert_many!(
                     "rfc53_updates",
                     ~w(fact_key payload kind),
                     [
                       ["a", "first", "original"],
                       ["b", "other", "b"],
                       ["a", "last", "replacement"]
                     ],
                     conflict: {:update, ~w(fact_key), ~w(payload)}
                   )
                 end)

        assert Repo.query!("SELECT fact_key,payload,kind FROM rfc53_updates ORDER BY fact_key").rows ==
                 [["a", "last", "original"], ["b", "other", "b"]]

        assert {:ok, :ok} =
                 Repo.transaction(fn ->
                   PGAuthorityImport.insert_many!(
                     "rfc53_updates",
                     ~w(fact_key payload kind),
                     [["c", "first", "c"], ["c", "ignored", "other"]],
                     conflict: {:nothing, ~w(fact_key)}
                   )
                 end)

        assert Repo.query!("SELECT payload FROM rfc53_updates WHERE fact_key='c'").rows == [
                 ["first"]
               ]
      after
        Repo.query!("DROP TABLE rfc53_updates")
      end
    end)
  end

  test "unknown settlement requires exact phase, original cursor and next step" do
    expected = %{cursor: %{"phase" => "agents", "scope" => "original"}, step: 0}
    next = %{"phase" => "sessions", "scope" => "original"}

    assert {:ok, position} =
             PGAuthorityImport.commit_page(:s, expected, next, fn -> fact!(%{}) end)

    frozen = %PGAuthorityImport.Pending{
      unit: :s,
      expected: expected,
      next: next,
      apply: fn -> flunk("settled page reran") end,
      stats: %{}
    }

    assert {:ok, ^position} = PGAuthorityImport.settle_page(frozen)

    assert {:error, :import_outcome_unknown, _} =
             PGAuthorityImport.settle_page(%{
               frozen
               | next: %{"phase" => "sessions", "scope" => "other"}
             })
  end

  test "a real lost COMMIT reply resumes the frozen page without applying facts twice" do
    config = Repo.config()
    {proxy, port} = CommitReplyProxy.start(config[:port], self())

    {:ok, isolated} =
      Repo.start_link(
        Keyword.merge(config,
          name: nil,
          pool_size: 1,
          hostname: "127.0.0.1",
          port: port,
          ssl: false,
          after_connect: nil,
          timeout: :infinity,
          connect_timeout: :infinity
        )
      )

    expected = %{cursor: %{"phase" => "agents"}, step: 0}
    next = %{"phase" => "complete"}
    parent = self()

    frozen =
      try do
        committing =
          SystemsRuntime.Task.async(fn ->
            Repo.put_dynamic_repo(isolated)
            Repo.query!("SELECT 1")
            send(proxy, {:arm, self()})
            receive do: (:armed -> :ok)

            PGAuthorityImport.commit_page(:s, expected, next, fn ->
              send(parent, :facts_applied)
              fact!(%{"accepted" => "once"})
            end)
          end)

        assert {:error, :import_outcome_unknown, pending} = settled_await(committing)
        settle_receive(:commit_reply_dropped)
        pending
      after
        Supervisor.stop(isolated)
      end

    settle_receive(:facts_applied)
    assert {:ok, %{step: 1, phase: "complete"}} = PGAuthorityImport.settle_page(frozen)
    refute_received :facts_applied

    %{rows: [[%{"accepted" => "once"}]]} =
      Repo.query!("SELECT evidence FROM salix_cutover_markers WHERE name='g1-import-fact'")
  end

  defp fact!(evidence),
    do:
      PGAuthorityImport.insert_exact!("salix_cutover_markers", ["name"], %{
        "name" => "g1-import-fact",
        "completed_at" => ~U[2026-01-01 00:00:00Z],
        "evidence" => evidence
      })
end
