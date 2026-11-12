defmodule SalixVerifiedKernel.MemoryStatsTest do
  # The counters are node-wide. Running alone keeps other tests from creating
  # handles meanwhile; handles released elsewhere only lower the counts.
  use ExUnit.Case, async: false

  alias SalixVerifiedKernel.{Session, Terminal}

  @count 50
  @blob_bytes 262_144
  @extra 64

  test "counts the live terminals and resident states this process holds" do
    terminals = for _ <- 1..@count, do: Terminal.new()
    sessions = for n <- 1..@count, do: Session.new("agent", "session-#{n}")
    stats = SalixVerifiedKernel.memory_stats()

    assert stats.terminals >= length(terminals)
    assert stats.residents >= length(sessions)
    assert stats.lineages >= length(sessions)
  end

  test "a read returns the caller's handle and adds no resident state" do
    {:verified_kernel, 1, :session_state, resident} = Session.new("agent", "reads")
    before = SalixVerifiedKernel.memory_stats().residents

    for _ <- 1..@count do
      assert {:ok, ^resident, _state} = SalixVerifiedKernel.invoke_session(resident, :export, nil)
    end

    assert SalixVerifiedKernel.memory_stats().residents <= before
  end

  test "reports how many residents the most crowded lineage holds" do
    first = Session.new("agent", "revisions")

    revisions =
      Enum.scan(1..@count, first, fn n, current ->
        {:done, next} =
          Session.step(current, %{"type" => "session_system_prompt", "prompt" => "p#{n}"})

        next
      end)

    stats = SalixVerifiedKernel.memory_stats()

    assert stats.lineage_residents_max >= length(Enum.uniq([first | revisions]))
    assert stats.lineage_residents_p50 <= stats.lineage_residents_p99
    assert stats.lineage_residents_p99 <= stats.lineage_residents_max
  end

  test "every stat is a nonnegative count" do
    sessions = for n <- 1..@count, do: Session.new("agent", "counts-#{n}")
    assert length(sessions) == @count

    for {key, value} <- SalixVerifiedKernel.memory_stats() do
      assert is_integer(value) and value >= 0, "#{key} is #{value}"
    end
  end

  test "reports the Lean heap and it grows with resident states" do
    before = SalixVerifiedKernel.memory_stats()
    assert before.lean_reserved_bytes > 0
    assert before.lean_resident_bytes > 0
    assert before.lean_resident_bytes <= before.lean_reserved_bytes

    # Each state carries a @blob_bytes name. Together they outgrow every page
    # that was already resident, so at least @extra of them need new pages.
    blob = :binary.copy("x", @blob_bytes)
    count = div(before.lean_resident_bytes, @blob_bytes) + @extra
    sessions = for n <- 1..count, do: Session.new("agent", "heap-#{n}", %{name: blob})
    stats = SalixVerifiedKernel.memory_stats()

    assert length(sessions) == count
    assert stats.lean_resident_bytes - before.lean_resident_bytes >= (@extra - 4) * @blob_bytes
    assert stats.lean_resident_bytes <= stats.lean_reserved_bytes
  end

  # The counts are node-wide: a handle another test dropped can leave them
  # at any time, so a release shows as a count at least one lower.
  test "a released handle drops its state without waiting for a collection" do
    {:verified_kernel, 1, :session_state, _} = handle = Session.new("agent", "released")
    with_handle = SalixVerifiedKernel.memory_stats().residents

    assert :ok = Session.release(handle)
    after_release = SalixVerifiedKernel.memory_stats().residents
    assert after_release <= with_handle - 1

    assert :ok = Session.release(handle)
    assert SalixVerifiedKernel.memory_stats().residents <= after_release

    assert_raise ArgumentError, fn -> Session.export(handle) end
  end

  # A released state's handle keeps its lineage until the VM collects the
  # handle. Such a lineage holds no Lean objects and is not counted as live.
  test "a lineage whose states were all released is counted apart" do
    handles = for n <- 1..@count, do: Session.new("agent", "lineage-released-#{n}")
    holding = SalixVerifiedKernel.memory_stats()

    for handle <- handles, do: assert(:ok = Session.release(handle))
    released = SalixVerifiedKernel.memory_stats()

    assert length(handles) == @count
    assert released.lineages <= holding.lineages - @count
    assert released.released_lineages >= @count
  end

  test "a released revision cursor drops its state like a state handle" do
    handle = Session.new("agent", "cursor-released")
    cursor = Session.start_revision(handle, nil)
    with_both = SalixVerifiedKernel.memory_stats().residents

    assert :ok = Session.release(cursor)
    without_cursor = SalixVerifiedKernel.memory_stats().residents
    assert without_cursor <= with_both - 1
    assert_raise ArgumentError, fn -> Session.revision_view(cursor) end

    assert :ok = Session.release(handle)
    assert SalixVerifiedKernel.memory_stats().residents <= without_cursor - 1
  end

  test "reports the C heap on glibc" do
    stats = SalixVerifiedKernel.memory_stats()

    if match?({:unix, :linux}, :os.type()) do
      assert stats.malloc_in_use_bytes > 0
      assert stats.malloc_arena_bytes >= stats.malloc_in_use_bytes
    end
  end
end
