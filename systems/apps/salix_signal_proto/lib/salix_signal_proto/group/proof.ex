defmodule SalixSignalProto.Group.Proof do
  @moduledoc """
  Fiat–Shamir proofs of knowledge of scalars that satisfy linear equations
  over ristretto255 points (CRS-09a section 10). The group credentials, the
  notary signature and group send endorsements use them.

  A statement is a list of equations `{lhs, [{scalar, point}, ...]}` whose
  entries are names (atoms). The point name `:base` is the base point `B`
  and always has index 0. Other points get indices in order of first
  appearance, left-hand side first; scalars get indices in order of first
  appearance in the terms. `description/1` returns the description string
  `D` of section 10.1.

  `prove/5` takes the witness scalars and point values as maps from name to
  32-byte encoding. The proof is `sc(c) ‖ sc(s_0) ‖ … ‖ sc(s_{k−1})`.
  """

  alias SalixSignalProto.Crypto.Ristretto255, as: R
  alias SalixSignalProto.Group.Sho

  @label "POKSHO_Ristretto_SHOHMACSHA256"
  @max_responses 256

  @type name :: atom()
  @type statement :: [{name(), [{name(), name()}]}]

  @doc "The point names (index order, `:base` first) and scalar names of a statement."
  @spec indices(statement()) :: {[name()], [name()]}
  def indices(statement) do
    {points, scalars} =
      Enum.reduce(statement, {[:base], []}, fn {lhs, terms}, {points, scalars} ->
        points = add_new(points, lhs)

        Enum.reduce(terms, {points, scalars}, fn {scalar, point}, {ps, ss} ->
          {add_new(ps, point), add_new(ss, scalar)}
        end)
      end)

    {points, scalars}
  end

  defp add_new(list, name), do: if(name in list, do: list, else: list ++ [name])

  @doc "The description string `D` (section 10.1)."
  @spec description(statement()) :: binary()
  def description(statement) do
    {points, scalars} = indices(statement)
    point_index = index_map(points)
    scalar_index = index_map(scalars)

    equations =
      for {lhs, terms} <- statement, into: <<>> do
        body =
          for {scalar, point} <- terms,
              into: <<>>,
              do: <<Map.fetch!(scalar_index, scalar), Map.fetch!(point_index, point)>>

        <<Map.fetch!(point_index, lhs), length(terms)>> <> body
      end

    <<length(statement)>> <> equations
  end

  defp index_map(names), do: names |> Enum.with_index() |> Map.new()

  @doc """
  Proves `statement` for the witness `scalars` and point values `points`
  (`:base` is filled in), binding `message`, with 32 bytes of randomness.
  """
  @spec prove(
          statement(),
          %{name() => R.scalar()},
          %{name() => R.element()},
          binary(),
          <<_::256>>
        ) ::
          binary()
  def prove(statement, scalars, points, message, <<_::binary-size(32)>> = randomness)
      when is_binary(message) do
    {point_names, scalar_names} = indices(statement)
    points = Map.put(points, :base, R.generator())
    transcript = transcript(statement, point_names, points)
    witness = Enum.map(scalar_names, &Map.fetch!(scalars, &1))

    {nonce_bytes, _state} =
      transcript
      |> Sho.absorb_and_ratchet([randomness | witness])
      |> Sho.absorb_and_ratchet(message)
      |> Sho.squeeze(64 * length(witness))

    nonces =
      for <<chunk::binary-size(64) <- nonce_bytes>>, do: R.scalar_from_wide_bytes(chunk)

    nonce_map = Map.new(Enum.zip(scalar_names, nonces))

    commitments =
      for {_lhs, terms} <- statement do
        sum(for {scalar, point} <- terms, do: R.mul(nonce_map[scalar], points[point]))
      end

    c = challenge(transcript, commitments, message)

    responses =
      for {r, w} <- Enum.zip(nonces, witness), do: R.scalar_add(r, R.scalar_mul(c, w))

    IO.iodata_to_binary([c | responses])
  end

  @doc """
  Verifies a proof (section 10.3). `points` are the public point values;
  `:base` is filled in. Returns false for any malformed proof or missing
  point.
  """
  @spec verify(statement(), %{name() => R.element()}, binary(), binary()) :: boolean()
  def verify(statement, points, message, proof) when is_binary(proof) and is_binary(message) do
    {point_names, scalar_names} = indices(statement)
    points = Map.put(points, :base, R.generator())

    with true <- rem(byte_size(proof), 32) == 0 and byte_size(proof) >= 64,
         chunks = for(<<chunk::binary-size(32) <- proof>>, do: chunk),
         [c | responses] = chunks,
         true <- length(responses) <= @max_responses,
         true <- length(responses) == length(scalar_names),
         true <- Enum.all?(chunks, &match?({:ok, _}, R.decode_scalar(&1))),
         true <- Enum.all?(point_names, &valid_point?(points, &1)) do
      response_map = Map.new(Enum.zip(scalar_names, responses))
      neg_c = R.scalar_negate(c)

      commitments =
        for {lhs, terms} <- statement do
          terms
          |> Enum.map(fn {scalar, point} -> R.mul(response_map[scalar], points[point]) end)
          |> sum()
          |> R.add(R.mul(neg_c, points[lhs]))
        end

      transcript = transcript(statement, point_names, points)
      challenge(transcript, commitments, message) == c
    else
      _ -> false
    end
  end

  defp valid_point?(points, name) do
    case Map.fetch(points, name) do
      {:ok, point} when is_binary(point) -> R.valid?(point)
      _ -> false
    end
  end

  defp transcript(statement, point_names, points) do
    encoded = Enum.map(point_names, &Map.fetch!(points, &1))
    Sho.new(@label) |> Sho.absorb_and_ratchet([description(statement) | encoded])
  end

  defp challenge(transcript, commitments, message) do
    {c, _state} =
      transcript |> Sho.absorb_and_ratchet([commitments, message]) |> Sho.squeeze_scalar()

    c
  end

  @doc "Sums a list of elements; the empty sum is the identity."
  @spec sum([R.element()]) :: R.element()
  def sum(elements), do: Enum.reduce(elements, R.identity(), &R.add(&2, &1))
end
