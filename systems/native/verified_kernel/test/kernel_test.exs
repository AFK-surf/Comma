defmodule SalixVerifiedKernelTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel, as: Kernel

  test "ETF preserves ordinary BEAM data across the static Lean boundary" do
    values = [
      nil,
      false,
      true,
      :λ,
      -2_147_483_649,
      2 ** 100,
      1.25,
      -0.0,
      <<1::1>>,
      [1, 2 | :tail],
      <<0, 255, 128>>,
      [],
      [0, 255, 256],
      {1, :ok, "你好"},
      %{1 => :integer, 1.0 => :float, "nested" => %{items: MapSet.new([1, 2])}}
    ]

    for value <- values do
      assert {:ok, ^value} = Kernel.invoke(:codec, :roundtrip, value)
    end
  end

  test "wire failures and runtime identities fail explicitly" do
    for value <- [self(), make_ref(), fn -> :opaque end, &Enum.map/2] do
      assert {:error, :wire, "unsupported_tag"} = Kernel.invoke(:codec, :roundtrip, value)
    end

    assert {:error, :wire, "unsupported_request"} = Kernel.invoke(:unknown, :run, [])

    for bytes <- [
          <<>>,
          <<131>>,
          <<131, 109, 255, 255, 255, 255>>,
          <<131, 97, 1, 0>>,
          <<131, 108, 0, 0, 0, 1, 97, 1, 97, 2>>,
          <<131, 80>>
        ] do
      result = bytes |> SalixVerifiedKernel.Native.invoke_etf() |> :erlang.binary_to_term([:safe])
      assert {1, :error, :wire, _} = result
    end
  end

  test "a cold VM decodes receipt continuation instructions and failures" do
    code = """
    evidence = %{sources: [{"source", {:receipt, "id"}}]}
    {:ok, {:ok, {operation, "id", []}}} =
      SalixVerifiedKernel.invoke(:ifc, :transfer_start, {evidence})
    IO.puts(Atom.to_string(operation))

    for observation <- [{:ok, false}, {:error, :unavailable}] do
      {:ok, {:ok, {:error, reason}}} =
        SalixVerifiedKernel.invoke(:ifc, :transfer_resume, {[], observation})
      IO.puts(Atom.to_string(reason))
    end
    """

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "--erl",
          "+S 2:2",
          "-pa",
          Path.dirname(to_string(:code.which(Kernel))),
          "-e",
          code
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "consume"
    assert output =~ "receipt_already_used"
    assert output =~ "receipt_unavailable"
  end

  test "concurrent calls do not share state or corrupt thread-local allocation" do
    1..16
    |> Task.async_stream(
      fn id ->
        for n <- 1..100 do
          payload = %{id: id, n: n, bytes: :binary.copy(<<id>>, 4096)}
          assert {:ok, ^payload} = Kernel.invoke(:codec, :roundtrip, payload)
        end
      end,
      max_concurrency: 8,
      timeout: 30_000
    )
    |> Enum.each(fn result -> assert {:ok, _} = result end)
  end

  test "truncation and nesting fail within the wire bounds" do
    request = :erlang.term_to_binary({1, :codec, 1, :roundtrip, %{data: [1, 2, {3, "bytes"}]}})

    for size <- 0..(byte_size(request) - 1) do
      result = request |> binary_part(0, size) |> SalixVerifiedKernel.Native.invoke_etf()
      assert {1, :error, :wire, _} = :erlang.binary_to_term(result, [:safe])
    end

    nested = Enum.reduce(1..65, nil, fn _, value -> {value} end)
    assert {:error, :wire, "depth_limit"} = Kernel.invoke(:codec, :roundtrip, nested)

    large = :binary.copy(<<0>>, 1_048_577)
    assert {:ok, ^large} = Kernel.invoke(:codec, :roundtrip, large)
    large_integer = 2 ** 40_000
    assert {:ok, ^large_integer} = Kernel.invoke(:codec, :roundtrip, large_integer)
  end
end
