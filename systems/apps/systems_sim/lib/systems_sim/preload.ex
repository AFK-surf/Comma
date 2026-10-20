defmodule SystemsSim.Preload do
  @moduledoc """
  Loads every module of the loaded applications before the tests start, its
  atoms first, in one order on every run.

  A module's atoms join the node's atom table when it loads: the names of its
  atom chunk, then those of the terms of its literal table. The table's order
  decides the order of a small map's atom keys and of an ETS table's keys that
  hold atoms. Modules that load in parallel, or on first call while the
  applications' processes start, would order them differently on every run,
  and code that walks such a map or table would take other steps. So the
  atoms of every module are made first, one module after another in the order
  of the applications' names and then the modules' names, and the modules then
  load in parallel without making any.
  """

  @doc "Makes the atoms of every module of the loaded applications, then loads them."
  @spec modules() :: :ok
  def modules do
    modules =
      for {app, _, _} <- Enum.sort(Application.loaded_applications()),
          module <- Enum.sort(Application.spec(app, :modules) || []),
          do: {app, module}

    modules
    |> Task.async_stream(&atoms/1, ordered: true, timeout: :infinity)
    |> Enum.each(fn {:ok, {names, literals}} ->
      Enum.each(names, &:erlang.binary_to_atom(&1, :utf8))
      Enum.each(literals, &:erlang.binary_to_term/1)
    end)

    :code.ensure_modules_loaded(Enum.map(modules, &elem(&1, 1)))
    :ok
  end

  # A module's atom names and its literals' encodings, read without making an
  # atom: reading them here, in parallel, would make them in a different
  # order on every run. (An application in an archive, as Hex, has no
  # directory: its modules make their atoms as they load.)
  defp atoms({app, module}) do
    with dir when is_list(dir) <- :code.lib_dir(app),
         {:ok, <<"FOR1", _size::32, "BEAM", chunks::binary>>} <-
           File.read(Path.join([dir, "ebin", "#{module}.beam"])) do
      {chunks |> chunk("AtU8") |> names(), chunks |> chunk("LitT") |> literals()}
    else
      _ -> {[], []}
    end
  end

  defp chunk(<<id::binary-4, size::32, data::binary-size(size), rest::binary>>, id) do
    _ = rest
    data
  end

  defp chunk(<<_id::binary-4, size::32, rest::binary>>, id) do
    padded = 4 * div(size + 3, 4)
    <<_::binary-size(^padded), rest::binary>> = rest
    chunk(rest, id)
  end

  defp chunk(_chunks, _id), do: nil

  # A non-negative count gives each name's length in a byte; a negative one
  # in the compact form of the code chunk (lengths of up to 2047 bytes).
  defp names(<<count::signed-32, rest::binary>>) when count >= 0, do: short(count, rest)
  defp names(<<count::signed-32, rest::binary>>), do: compact(-count, rest)
  defp names(nil), do: []

  defp short(0, _rest), do: []

  defp short(n, <<length, name::binary-size(length), rest::binary>>),
    do: [name | short(n - 1, rest)]

  defp compact(0, _rest), do: []

  defp compact(n, <<length::4, 0::1, _tag::3, rest::binary>>), do: compact_name(n, length, rest)

  defp compact(n, <<high::3, 0b01::2, _tag::3, low, rest::binary>>),
    do: compact_name(n, high * 256 + low, rest)

  defp compact_name(n, length, rest) do
    <<name::binary-size(^length), rest::binary>> = rest
    [name | compact(n - 1, rest)]
  end

  # The literal table: its uncompressed size (0 when it is stored as is),
  # then the count of terms and each term's encoding.
  defp literals(<<0::32, table::binary>>), do: terms(table)
  defp literals(<<_size::32, deflated::binary>>), do: terms(:zlib.uncompress(deflated))
  defp literals(nil), do: []

  defp terms(<<count::32, rest::binary>>), do: terms(count, rest)

  defp terms(0, _rest), do: []

  defp terms(n, <<size::32, term::binary-size(size), rest::binary>>),
    do: [term | terms(n - 1, rest)]
end
