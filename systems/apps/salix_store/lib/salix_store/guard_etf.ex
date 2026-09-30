defmodule SalixStore.GuardETF do
  @moduledoc """
  Retires guard diagnostic fields in raw ETF before allocating their term heap.
  Only State.events is visited; untouched term bytes are copied verbatim.
  Framing follows https://www.erlang.org/doc/apps/erts/erl_ext_dist.html.
  Unsupported/truncated/deep encodings fail closed, never decode the old term.
  """
  def clean(<<131, body::binary>>, limit) do
    clean = root(body)

    if IO.iodata_length(clean) + 1 > limit,
      do: {:error, :non_guard_oversized_snapshot},
      else: {:ok, IO.iodata_to_binary([131, clean])}
  rescue
    _ -> {:error, :invalid_snapshot}
  catch
    :invalid -> {:error, :invalid_snapshot}
  end

  def clean(_, _), do: {:error, :invalid_snapshot}

  defp root(<<104, 3, rest::binary>>) do
    {[tag, version, state], <<>>} = parts(rest, 3)
    true = name(tag) == {:atom, "comma_internal_session"} and version == <<97, 3>>
    [<<104, 3>>, tag, version, state(state)]
  end

  defp root(body), do: state(body)

  defp state(body) do
    pairs = pairs(body)

    true =
      name(value(pairs, {:atom, "__struct__"})) ==
        {:atom, "Elixir.SalixAgent.InternalSession.State"}

    encode_pairs(
      Enum.map(pairs, fn {k, v} ->
        {k, if(name(k) == {:atom, "events"}, do: events(v), else: v)}
      end)
    )
  end

  defp events(<<108, n::32, rest::binary>>) when n <= 100_000 do
    {items, <<106>>} = parts(rest, n)
    [<<108, n::32>>, Enum.map(items, &event/1), <<106>>]
  end

  defp events(<<108, _::binary>>), do: throw(:invalid)
  defp events(other), do: other

  defp event(<<116, _::binary>> = body) do
    pairs = pairs(body)
    kind = name(value(pairs, {:binary, "kind"}))

    if kind in [{:binary, "runaway_guard_reset"}, {:binary, "runaway_unsettled_round"}] do
      encode_pairs(
        Enum.map(pairs, fn
          {k, <<116, _::binary>> = v} ->
            {k,
             if(name(k) == {:binary, "event"},
               do:
                 encode_pairs(
                   Enum.reject(pairs(v), fn {key, _} ->
                     name(key) == {:binary, "activation_key"}
                   end)
                 ),
               else: v
             )}

          pair ->
            pair
        end)
      )
    else
      body
    end
  end

  defp event(body), do: body

  defp pairs(<<116, n::32, rest::binary>>) when n <= 256 do
    {items, <<>>} = parts(rest, n * 2)
    items |> Enum.chunk_every(2) |> Enum.map(fn [k, v] -> {k, v} end)
  end

  defp value(pairs, key), do: Enum.find_value(pairs, fn {k, v} -> if name(k) == key, do: v end)

  defp encode_pairs(pairs),
    do: [<<116, length(pairs)::32>>, Enum.map(pairs, fn {k, v} -> [k, v] end)]

  defp name(<<109, n::32, s::binary-size(n)>>) when n <= 64, do: {:binary, s}
  defp name(<<tag, n::16, s::binary-size(n)>>) when tag in [100, 118] and n <= 64, do: {:atom, s}
  defp name(<<tag, n, s::binary-size(n)>>) when tag in [115, 119] and n <= 64, do: {:atom, s}
  defp name(_), do: nil

  defp parts(body, n), do: parts(body, n, [])
  defp parts(body, 0, acc), do: {Enum.reverse(acc), body}

  defp parts(body, n, acc) do
    rest = skip(body, 0)
    part = binary_part(body, 0, byte_size(body) - byte_size(rest))
    parts(rest, n - 1, [part | acc])
  end

  defp skip(_, depth) when depth > 128, do: throw(:invalid)
  defp skip(<<106, r::binary>>, _), do: r
  defp skip(<<97, _::8, r::binary>>, _), do: r
  defp skip(<<98, _::32, r::binary>>, _), do: r
  defp skip(<<70, _::64, r::binary>>, _), do: r
  defp skip(<<99, _::248, r::binary>>, _), do: r
  defp skip(<<t, n::16, _::binary-size(n), r::binary>>, _) when t in [100, 107, 118], do: r
  defp skip(<<t, n, _::binary-size(n), r::binary>>, _) when t in [115, 119], do: r
  defp skip(<<109, n::32, _::binary-size(n), r::binary>>, _), do: r
  defp skip(<<77, n::32, _bits, _::binary-size(n), r::binary>>, _), do: r
  defp skip(<<110, n, _sign, _::binary-size(n), r::binary>>, _), do: r
  defp skip(<<111, n::32, _sign, _::binary-size(n), r::binary>>, _), do: r
  defp skip(<<104, n, r::binary>>, d), do: skip_n(r, n, d + 1)
  defp skip(<<105, n::32, r::binary>>, d), do: skip_n(r, n, d + 1)
  defp skip(<<108, n::32, r::binary>>, d), do: skip_n(r, n + 1, d + 1)
  defp skip(<<116, n::32, r::binary>>, d), do: skip_n(r, n * 2, d + 1)
  defp skip(_, _), do: throw(:invalid)
  defp skip_n(body, 0, _), do: body
  defp skip_n(body, n, d), do: skip_n(skip(body, d), n - 1, d)
end
