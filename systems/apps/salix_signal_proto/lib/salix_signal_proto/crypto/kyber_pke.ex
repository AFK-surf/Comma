defmodule SalixSignalProto.Crypto.KyberPke do
  @moduledoc """
  The lattice public-key encryption shared by CRYSTALS-Kyber round 3
  (CPAPKE, specification v3.02 §1.5) and FIPS 203 (K-PKE, §5), with
  eta1 = eta2 = 2 and module rank k, compression du and dv as parameters.

  `SalixSignalProto.Crypto.Kyber1024` (k = 4, du = 11, dv = 5) and
  `SalixSignalProto.Crypto.MlKem768` (k = 3, du = 10, dv = 4) build their
  KEMs on it. The two specifications differ only outside this module: in the
  key-generation seed expansion and in the KEM transforms.

  Plain Elixir. The arithmetic has no secret-dependent branches, but the BEAM
  gives no constant-time guarantee for integer arithmetic.
  """

  import Bitwise

  @q 3329
  @poly_bytes 384
  # 128^-1 mod q, the scale factor of the inverse NTT.
  @inv_128 3303
  # SHAKE128 block size; SampleNTT reads whole blocks.
  @xof_block 168

  bitrev7 = fn i ->
    Enum.reduce(0..6, 0, fn bit, acc -> bor(acc, (i >>> bit &&& 1) <<< (6 - bit)) end)
  end

  pow_mod = fn base, exp -> :binary.decode_unsigned(:crypto.mod_pow(base, exp, @q)) end

  # zetas[i] = 17^bitrev7(i) and gammas[i] = 17^(2 bitrev7(i) + 1), mod q.
  @zetas List.to_tuple(for i <- 0..127, do: pow_mod.(17, bitrev7.(i)))
  @gammas for i <- 0..127, do: pow_mod.(17, 2 * bitrev7.(i) + 1)

  @typedoc "Parameters: module rank `k` and compression `du`, `dv`."
  @type params :: %{k: pos_integer(), du: pos_integer(), dv: pos_integer()}

  @doc "Encoded size of the vector t or s: 384 k bytes."
  def vector_bytes(%{k: k}), do: k * @poly_bytes

  @doc "Size of the u part of a ciphertext."
  def u_bytes(%{k: k, du: du}), do: k * div(256 * du, 8)

  @doc "Size of the v part of a ciphertext."
  def v_bytes(%{dv: dv}), do: div(256 * dv, 8)

  @doc """
  Key generation from the 32-byte seeds rho and sigma. Returns
  `{encode_12(t_hat) || rho, encode_12(s_hat)}`.
  """
  @spec keygen(<<_::256>>, <<_::256>>, params()) :: {binary(), binary()}
  def keygen(rho, sigma, %{k: k}) do
    a_hat = for i <- 0..(k - 1), do: for(j <- 0..(k - 1), do: sample_ntt(rho, j, i))
    s_hat = for n <- 0..(k - 1), do: sigma |> prf(n) |> cbd() |> ntt()
    e_hat = for n <- k..(2 * k - 1), do: sigma |> prf(n) |> cbd() |> ntt()

    t_hat =
      a_hat
      |> Enum.map(&dot(&1, s_hat))
      |> Enum.zip_with(e_hat, &poly_add/2)

    {encode_vector(t_hat, 12) <> rho, encode_vector(s_hat, 12)}
  end

  @doc "Encrypts the 32-byte message m with the 32-byte randomness r."
  @spec encrypt(binary(), <<_::256>>, <<_::256>>, params()) :: binary()
  def encrypt(ek, m, r, params) do
    t_size = vector_bytes(params)
    <<t_encoded::binary-size(^t_size), rho::binary-size(32)>> = ek
    encrypt_u(rho, r, params) <> encrypt_v(t_encoded, r, m, params)
  end

  @doc """
  The u part of a ciphertext: `encode_du(compress_du(NTT^-1(A^T ∘ NTT(y)) +
  e1))`. It depends on rho and r only.
  """
  @spec encrypt_u(<<_::256>>, <<_::256>>, params()) :: binary()
  def encrypt_u(rho, r, %{k: k, du: du}) do
    at_hat = for i <- 0..(k - 1), do: for(j <- 0..(k - 1), do: sample_ntt(rho, i, j))
    y_hat = y_hat(r, k)
    e1 = for n <- k..(2 * k - 1), do: r |> prf(n) |> cbd()

    at_hat
    |> Enum.map(&(&1 |> dot(y_hat) |> inv_ntt()))
    |> Enum.zip_with(e1, &poly_add/2)
    |> Enum.map(&compress(&1, du))
    |> encode_vector(du)
  end

  @doc """
  The v part of a ciphertext: `encode_dv(compress_dv(NTT^-1(t^T ∘ NTT(y)) +
  e2 + decompress_1(m)))`. `t_encoded` is the 384 k-byte encoding of t_hat.
  """
  @spec encrypt_v(binary(), <<_::256>>, <<_::256>>, params()) :: binary()
  def encrypt_v(t_encoded, r, m, %{k: k, dv: dv}) do
    t_hat = decode_vector(t_encoded, 12)
    e2 = r |> prf(2 * k) |> cbd()
    message = m |> decode(1) |> Enum.map(&decompress(&1, 1))

    t_hat
    |> dot(y_hat(r, k))
    |> inv_ntt()
    |> poly_add(e2)
    |> poly_add(message)
    |> compress(dv)
    |> encode(dv)
  end

  @doc "Decrypts a ciphertext with the 384 k-byte secret key; returns the 32-byte message."
  @spec decrypt(binary(), binary(), params()) :: <<_::256>>
  def decrypt(dk_pke, c, %{du: du, dv: dv} = params) do
    u_size = u_bytes(params)
    <<c_u::binary-size(^u_size), c_v::binary>> = c
    u = c_u |> decode_vector(du) |> Enum.map(&decompress(&1, du))
    v = c_v |> decode(dv) |> decompress(dv)
    s_hat = decode_vector(dk_pke, 12)
    w = poly_sub(v, s_hat |> dot(Enum.map(u, &ntt/1)) |> inv_ntt())
    encode(compress(w, 1), 1)
  end

  @doc """
  True when every 12-bit value of an encoded vector is below q (the FIPS 203
  encapsulation-key modulus check).
  """
  @spec canonical_vector?(binary()) :: boolean()
  def canonical_vector?(encoded) when is_binary(encoded) do
    Enum.all?(
      for <<b0, b1, b2 <- encoded>>,
        do: b0 + 256 * (b1 &&& 15) < @q and (b1 >>> 4) + 16 * b2 < @q
    )
  end

  defp y_hat(r, k), do: for(n <- 0..(k - 1), do: r |> prf(n) |> cbd() |> ntt())

  # --- Sampling ---

  # SampleNTT / Parse: uniform rejection sampling from SHAKE128(rho || a || b).
  defp sample_ntt(rho, a, b), do: sample_ntt(rho <> <<a, b>>, 4)

  defp sample_ntt(seed, blocks) do
    stream = :crypto.hash_xof(:shake128, seed, blocks * @xof_block * 8)

    case parse(stream, [], 0) do
      {:ok, coefficients} -> coefficients
      :more -> sample_ntt(seed, blocks + 2)
    end
  end

  defp parse(_stream, acc, 256), do: {:ok, Enum.reverse(acc)}

  defp parse(<<b0, b1, b2, rest::binary>>, acc, count) do
    d1 = b0 + 256 * (b1 &&& 15)
    d2 = (b1 >>> 4) + 16 * b2
    {acc, count} = if d1 < @q, do: {[d1 | acc], count + 1}, else: {acc, count}

    {acc, count} =
      if d2 < @q and count < 256, do: {[d2 | acc], count + 1}, else: {acc, count}

    parse(rest, acc, count)
  end

  defp parse(_short, _acc, _count), do: :more

  # PRF(s, n) = SHAKE256(s || n), 64 * eta bytes with eta = 2.
  defp prf(seed, n), do: :crypto.hash_xof(:shake256, seed <> <<n>>, 128 * 8)

  # Centered binomial distribution with eta = 2: each nibble a0 a1 b0 b1
  # (least significant bit first) gives (a0 + a1) - (b0 + b1).
  defp cbd(<<_::binary-size(128)>> = bytes) do
    for <<byte <- bytes>>, nibble <- [byte &&& 15, byte >>> 4] do
      a = (nibble &&& 1) + (nibble >>> 1 &&& 1)
      b = (nibble >>> 2 &&& 1) + (nibble >>> 3 &&& 1)
      rem(a - b + @q, @q)
    end
  end

  # --- NTT ---

  defp ntt(f) do
    {f, _next} =
      Enum.reduce([128, 64, 32, 16, 8, 4, 2], {f, 1}, fn len, {f, k} ->
        {blocks, k} =
          f
          |> Enum.chunk_every(2 * len)
          |> Enum.map_reduce(k, fn block, k ->
            {low, high} = Enum.split(block, len)
            zeta = elem(@zetas, k)
            t = Enum.map(high, &rem(zeta * &1, @q))
            sums = Enum.zip_with(low, t, &rem(&1 + &2, @q))
            differences = Enum.zip_with(low, t, &rem(&1 - &2 + @q, @q))
            {sums ++ differences, k + 1}
          end)

        {Enum.concat(blocks), k}
      end)

    f
  end

  defp inv_ntt(f) do
    {f, _next} =
      Enum.reduce([2, 4, 8, 16, 32, 64, 128], {f, 127}, fn len, {f, k} ->
        {blocks, k} =
          f
          |> Enum.chunk_every(2 * len)
          |> Enum.map_reduce(k, fn block, k ->
            {low, high} = Enum.split(block, len)
            zeta = elem(@zetas, k)
            sums = Enum.zip_with(low, high, &rem(&1 + &2, @q))
            differences = Enum.zip_with(low, high, &rem(zeta * (&2 - &1 + @q), @q))
            {sums ++ differences, k - 1}
          end)

        {Enum.concat(blocks), k}
      end)

    Enum.map(f, &rem(&1 * @inv_128, @q))
  end

  # Multiplication in the NTT domain: 128 products of degree-1 polynomials
  # modulo X^2 - gamma_i.
  defp basemul(a, b) do
    [Enum.chunk_every(a, 2), Enum.chunk_every(b, 2), @gammas]
    |> Enum.zip_with(fn [[a0, a1], [b0, b1], gamma] ->
      [rem(a0 * b0 + rem(a1 * b1, @q) * gamma, @q), rem(a0 * b1 + a1 * b0, @q)]
    end)
    |> Enum.concat()
  end

  defp dot(row, vector) do
    row
    |> Enum.zip_with(vector, &basemul/2)
    |> Enum.reduce(&poly_add/2)
  end

  defp poly_add(a, b), do: Enum.zip_with(a, b, &rem(&1 + &2, @q))
  defp poly_sub(a, b), do: Enum.zip_with(a, b, &rem(&1 - &2 + @q, @q))

  # --- Compression and encoding ---

  # Compress_d(x) = round(2^d / q * x) mod 2^d, ties rounded up.
  defp compress(f, d), do: Enum.map(f, &(div((&1 <<< (d + 1)) + @q, 2 * @q) &&& (1 <<< d) - 1))

  # Decompress_d(y) = round(q / 2^d * y), ties rounded up.
  defp decompress(f, d) when is_list(f), do: Enum.map(f, &decompress(&1, d))
  defp decompress(y, d), do: (y * @q + (1 <<< (d - 1))) >>> d

  # Encode_l: 256 l-bit values, least significant bit first.
  defp encode(f, l) do
    value = f |> Enum.with_index() |> Enum.reduce(0, fn {c, i}, acc -> acc ||| c <<< (l * i) end)
    <<value::little-size(l * 256)>>
  end

  defp encode_vector(polys, l), do: polys |> Enum.map(&encode(&1, l)) |> IO.iodata_to_binary()

  # Decode_l. 12-bit values are reduced modulo q, so a key with values at or
  # above q is used as its residues (round 3 applies no input check).
  defp decode(bytes, l) do
    value = :binary.decode_unsigned(bytes, :little)
    mask = (1 <<< l) - 1
    coefficients = for i <- 0..255, do: value >>> (l * i) &&& mask
    if l == 12, do: Enum.map(coefficients, &rem(&1, @q)), else: coefficients
  end

  defp decode_vector(bytes, l) do
    size = div(256 * l, 8)
    for <<chunk::binary-size(^size) <- bytes>>, do: decode(chunk, l)
  end
end
