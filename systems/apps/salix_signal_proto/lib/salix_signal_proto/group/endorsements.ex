defmodule SalixSignalProto.Group.Endorsements do
  @moduledoc """
  Group send endorsements (CRS-09a section 15). A sender proves to the chat
  server that it shares a group with the recipients of a multi-recipient
  sealed-sender message (CRS-09c) without revealing the group.

  | Object | Bytes | Layout |
  | --- | --- | --- |
  | Response | `89 + 32·n` | `0x00 ‖ le64(n) ‖ enc(R_0) … ‖ le64(64) ‖ proof ‖ le64(ε)` |
  | Endorsement | 33 | `0x00 ‖ enc(R)` |
  | Token | 25 | `0x00 ‖ le64(16) ‖ token` |
  | Full token | 33 | `0x00 ‖ le64(16) ‖ token ‖ le64(ε)` |

  The full token goes in the `Group-Send-Token` header as standard base64
  (`header_value/1`).

  `key_pair/2`, `issue/3` and `verify_full_token/4` are the server side, for
  test servers and the mock chat server.
  """

  alias SalixSignalProto.Crypto.Ristretto255, as: R
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Group.Proof
  alias SalixSignalProto.Group.ServerParams
  alias SalixSignalProto.Group.Sho
  alias SalixSignalProto.Group.Uid

  @tag_label "20240215_Signal_GroupSendEndorsement"
  @weights_label "Signal_ZKCredential_Endorsements_EndorsementResponse_ProofWeights_20240207"
  @day 86_400
  @min_lifetime 7_200
  @max_lifetime 604_800
  @statement [{:sum_r, [{:k, :sum_e}]}, {:base, [{:k, :pk}]}]

  @doc false
  def statement, do: @statement

  @type endorsement :: <<_::264>>

  @doc "`τ_ε`: the tag scalar of the expiration."
  @spec tag_scalar(non_neg_integer()) :: R.scalar()
  def tag_scalar(expiration) do
    {tag, _} = @tag_label |> Sho.derive(<<expiration::64>>) |> Sho.squeeze_scalar()
    tag
  end

  @doc "The derived public key `PK' = PK_e + τ_ε·B`."
  @spec derived_public_key(R.element(), non_neg_integer()) :: R.element()
  def derived_public_key(pk_e, expiration),
    do: R.add(pk_e, R.mul_base(tag_scalar(expiration)))

  @doc """
  Receives an endorsement response (section 15.4).

  `members` are the full members' service IDs, including the local user,
  in any order. Returns the endorsements in the order of `members`, the
  combined endorsement of every member except `local`, and the expiration.
  """
  @spec receive(
          ServerParams.Public.t(),
          Params.t(),
          binary(),
          [Uid.service_id()],
          Uid.service_id(),
          integer()
        ) ::
          {:ok, %{endorsements: [endorsement()], combined: endorsement(), expiration: integer()}}
          | {:error, :invalid}
  def receive(%ServerParams.Public{} = server, %Params{a1: a1}, response, members, local, now) do
    points = Enum.map(members, &R.mul(a1, Uid.m1(&1)))
    local_index = Enum.find_index(members, &(&1 == local))

    if local_index == nil,
      do: {:error, :invalid},
      else: receive_points(server, response, points, local_index, now)
  end

  @doc """
  Receives a response with the members given as 65-byte UID ciphertexts
  (the endorsed point is the first point `E1`). `local_ciphertext` names the
  local user.
  """
  @spec receive_ciphertexts(ServerParams.Public.t(), binary(), [binary()], binary(), integer()) ::
          {:ok, %{endorsements: [endorsement()], combined: endorsement(), expiration: integer()}}
          | {:error, :invalid}
  def receive_ciphertexts(
        %ServerParams.Public{} = server,
        response,
        ciphertexts,
        local_ciphertext,
        now
      ) do
    with {:ok, points} <- first_points(ciphertexts),
         index when is_integer(index) <- Enum.find_index(ciphertexts, &(&1 == local_ciphertext)) do
      receive_points(server, response, points, index, now)
    else
      _ -> {:error, :invalid}
    end
  end

  defp first_points(ciphertexts) do
    Enum.reduce_while(ciphertexts, {:ok, []}, fn ciphertext, {:ok, acc} ->
      case Uid.parse(ciphertext) do
        {:ok, {e1, _e2}} -> {:cont, {:ok, [e1 | acc]}}
        {:error, _} -> {:halt, {:error, :invalid}}
      end
    end)
    |> case do
      {:ok, points} -> {:ok, Enum.reverse(points)}
      error -> error
    end
  end

  defp receive_points(server, response, points, local_index, now) do
    n = length(points)
    r_bytes = 32 * n

    with <<0, ^n::little-64, rs::binary-size(^r_bytes), 64::little-64, proof::binary-size(64),
           expiration::little-64>> <- response,
         true <- valid_expiration?(expiration, now),
         received = for(<<r::binary-size(32) <- rs>>, do: r),
         true <- Enum.all?(received, &R.valid?/1) do
      pk = derived_public_key(server.endorsement, expiration)
      sorted = sort_indices(points)
      sorted_points = Enum.map(sorted, &Enum.at(points, &1))

      if verify_proof(pk, sorted_points, received, proof) do
        # The i-th received R endorses the i-th point in sorted order.
        by_member =
          sorted
          |> Enum.zip(received)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {_index, r} -> r end)

        others = by_member |> List.delete_at(local_index) |> Proof.sum()

        {:ok,
         %{
           endorsements: Enum.map(by_member, &(<<0>> <> &1)),
           combined: <<0>> <> others,
           expiration: expiration
         }}
      else
        {:error, :invalid}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp valid_expiration?(expiration, now) do
    rem(expiration, @day) == 0 and expiration - now >= @min_lifetime and
      expiration - now <= @max_lifetime
  end

  # Member indices in ascending order of enc(2·E_i).
  defp sort_indices(points) do
    points
    |> Enum.with_index()
    |> Enum.sort_by(fn {point, _i} -> R.add(point, point) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp verify_proof(pk, sorted_points, rs, proof) do
    {sum_e, sum_r} = weighted_sums(pk, sorted_points, rs)
    Proof.verify(@statement, %{sum_r: sum_r, sum_e: sum_e, pk: pk}, "", proof)
  end

  defp weighted_sums(pk, sorted_points, rs) do
    n = length(sorted_points)

    {bytes, _} =
      @weights_label
      |> Sho.new()
      |> Sho.absorb_and_ratchet([pk, Enum.map(sorted_points, &R.add(&1, &1)), rs])
      |> Sho.squeeze(16 * (n - 1))

    weights =
      [<<1::little-256>>] ++
        for <<chunk::binary-size(15), last <- bytes>>,
          do: <<chunk::binary, Bitwise.band(last, 0x7F), 0::128>>

    sum_e =
      weights |> Enum.zip(sorted_points) |> Enum.map(fn {w, p} -> R.mul(w, p) end) |> Proof.sum()

    sum_r = weights |> Enum.zip(rs) |> Enum.map(fn {w, r} -> R.mul(w, r) end) |> Proof.sum()
    {sum_e, sum_r}
  end

  @doc "Combines endorsements by point addition. The combination of none is the identity."
  @spec combine([endorsement()]) :: endorsement()
  def combine(endorsements) do
    <<0>> <> (endorsements |> Enum.map(&point!/1) |> Proof.sum())
  end

  @doc "Removes `removed` from the combined endorsement `endorsement`."
  @spec remove(endorsement(), endorsement()) :: endorsement()
  def remove(endorsement, removed), do: <<0>> <> R.sub(point!(endorsement), point!(removed))

  defp point!(<<0, point::binary-size(32)>>) do
    if R.valid?(point), do: point, else: raise(ArgumentError, "invalid endorsement")
  end

  defp point!(_other), do: raise(ArgumentError, "invalid endorsement")

  @doc "The 25-byte token of an endorsement: `SHA-256(enc(a1⁻¹·R))[0..16]`."
  @spec token(Params.t(), endorsement()) :: <<_::200>>
  def token(%Params{a1: a1}, endorsement) do
    {:ok, a1_inv} = R.scalar_invert(a1)
    digest = :crypto.hash(:sha256, R.mul(a1_inv, point!(endorsement)))
    <<0, 16::little-64, binary_part(digest, 0, 16)::binary>>
  end

  @doc "The 33-byte full token: the token and the expiration."
  @spec full_token(Params.t(), endorsement(), non_neg_integer()) :: <<_::264>>
  def full_token(%Params{} = params, endorsement, expiration),
    do: token(params, endorsement) <> <<expiration::little-64>>

  @doc "The `Group-Send-Token` header value: standard base64 with padding."
  @spec header_value(binary()) :: String.t()
  def header_value(full_token), do: Base.encode64(full_token)

  @doc false
  # Server side (section 15.1): the 73-byte derived key pair for ε.
  def key_pair(%ServerParams.Secret{endorsement: e}, expiration) do
    tag = tag_scalar(expiration)
    {:ok, k} = R.scalar_invert(R.scalar_add(e, tag))
    pk = R.add(R.mul_base(e), R.mul_base(tag))
    <<0, k::binary, pk::binary, expiration::little-64>>
  end

  @doc false
  # Server side (section 15.3): issues endorsements over member UID ciphertexts.
  def issue(
        ciphertexts,
        <<0, k::binary-size(32), pk::binary-size(32), expiration::little-64>>,
        randomness
      ) do
    {:ok, points} = first_points(ciphertexts)
    sorted_points = points |> sort_indices() |> Enum.map(&Enum.at(points, &1))
    rs = Enum.map(sorted_points, &R.mul(k, &1))
    {sum_e, sum_r} = weighted_sums(pk, sorted_points, rs)

    proof =
      Proof.prove(@statement, %{k: k}, %{sum_r: sum_r, sum_e: sum_e, pk: pk}, "", randomness)

    IO.iodata_to_binary([
      0,
      <<length(rs)::little-64>>,
      rs,
      <<64::little-64>>,
      proof,
      <<expiration::little-64>>
    ])
  end

  @doc false
  # Server side (section 15.6): checks a full token for a recipient set.
  def verify_full_token(
        <<0, 16::little-64, token::binary-size(16), expiration::little-64>>,
        service_ids,
        %ServerParams.Secret{} = secret,
        now
      ) do
    if now > expiration do
      false
    else
      <<0, k::binary-size(32), _pk::binary-size(32), _::64>> = key_pair(secret, expiration)
      point = R.mul(k, service_ids |> Enum.map(&Uid.m1/1) |> Proof.sum())
      binary_part(:crypto.hash(:sha256, point), 0, 16) == token
    end
  end

  def verify_full_token(_token, _service_ids, _secret, _now), do: false
end
