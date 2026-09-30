defmodule SalixSignalProto.Group.Storage do
  @moduledoc """
  Pure parts of the storage-service group API (CRS-09b sections 2, 3, 5 and
  9): request authorization, response decoding and the group context that
  group messages carry. The HTTP client is `SalixSignal.Groups.StorageClient`.
  """

  alias SalixSignalProto.Group.AuthCredential
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Group.ServerParams
  alias SalixSignalProto.Group.State
  alias SalixSignalProto.Group.Wire

  @day 86_400

  @doc """
  The `Authorization` header value for a storage request (section 3):
  `Basic base64(hex(group public params) ":" hex(presentation))`. Each
  request should use a fresh presentation.
  """
  @spec authorization(Params.t(), binary()) :: String.t()
  def authorization(%Params{} = params, presentation) when is_binary(presentation) do
    credentials =
      Base.encode16(Params.public_params(params), case: :lower) <>
        ":" <>
        Base.encode16(presentation, case: :lower)

    "Basic " <> Base.encode64(credentials)
  end

  @doc """
  Makes a fresh auth presentation for today from the received credentials
  (a map from redemption time to 265-byte credential) and returns the
  `Authorization` header value. `now` is Unix seconds.
  """
  @spec authorize(ServerParams.Public.t(), Params.t(), %{integer() => binary()}, integer()) ::
          {:ok, String.t()} | {:error, :no_credential | :invalid}
  def authorize(%ServerParams.Public{} = server, %Params{} = params, credentials, now) do
    today = now - Integer.mod(now, @day)

    with {:ok, credential} <- Map.fetch(credentials, today),
         {:ok, {presentation, _aci, _pni}} <- AuthCredential.present(server, params, credential) do
      {:ok, authorization(params, presentation)}
    else
      :error -> {:error, :no_credential}
      {:error, _} -> {:error, :invalid}
    end
  end

  @doc """
  The range of redemption days that clients request (section 2): today to
  today plus 7 days, as `{start, end}` Unix seconds.
  """
  @spec credential_range(integer()) :: {integer(), integer()}
  def credential_range(now) do
    today = now - Integer.mod(now, @day)
    {today, today + 7 * @day}
  end

  @doc """
  Receives the credentials of a `GET /v1/certificate/auth/group` response
  (section 2), decoded from JSON. `aci` is the raw ACI; the PNI comes from
  the response, or the account's `salt` when it is null. Credentials that
  do not verify are left out. Returns a map from redemption time to
  credential.
  """
  @spec receive_credentials(ServerParams.Public.t(), <<_::128>>, map(), binary() | nil) ::
          {:ok, %{integer() => binary()}} | {:error, :invalid}
  def receive_credentials(
        %ServerParams.Public{} = server,
        aci,
        %{"credentials" => entries} = body,
        salt
      )
      when is_list(entries) do
    with {:ok, pni} <- response_pni(body["pni"], salt) do
      received =
        for %{"credential" => encoded, "redemptionTime" => time} <- entries,
            is_integer(time),
            {:ok, response} <- [Base.decode64(encoded)],
            {:ok, credential} <- [AuthCredential.receive(server, aci, pni, time, response)],
            into: %{},
            do: {time, credential}

      {:ok, received}
    end
  end

  def receive_credentials(_server, _aci, _body, _salt), do: {:error, :invalid}

  defp response_pni(nil, salt) when is_binary(salt), do: {:ok, {:salt, salt}}

  defp response_pni(uuid, _salt) when is_binary(uuid) do
    case Base.decode16(String.replace(uuid, "-", ""), case: :mixed) do
      {:ok, <<_::binary-size(16)>> = raw} -> {:ok, raw}
      _ -> {:error, :invalid}
    end
  end

  defp response_pni(_pni, _salt), do: {:error, :invalid}

  @doc "Decodes a group response (`PUT` and `GET /v2/groups/`)."
  @spec decode_group_response(binary()) ::
          {:ok, %{group: struct(), endorsements: binary()}} | {:error, :invalid}
  def decode_group_response(bytes) do
    with {:ok, %Wire.GroupResponse{group: %Wire.Group{} = group, endorsements: e}} <-
           State.decode(Wire.GroupResponse, bytes) do
      {:ok, %{group: group, endorsements: e}}
    else
      _ -> {:error, :invalid}
    end
  end

  @doc "Decodes a change response (`PATCH /v2/groups/`); returns the signed change bytes."
  @spec decode_change_response(binary()) ::
          {:ok, %{change: binary(), endorsements: binary()}} | {:error, :invalid}
  def decode_change_response(bytes) do
    with {:ok, %Wire.ChangeResponse{change: %Wire.SignedChange{} = change, endorsements: e}} <-
           State.decode(Wire.ChangeResponse, bytes) do
      {:ok, %{change: Protobuf.encode(change), endorsements: e}}
    else
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Decodes a join-info response (`GET /v2/groups/join/<pw>`), decrypting the
  title and description with the group keys.
  """
  @spec decode_join_info(Params.t(), binary()) :: {:ok, map()} | {:error, :invalid}
  def decode_join_info(%Params{} = params, bytes) do
    with {:ok, %Wire.JoinInfo{} = info} <- State.decode(Wire.JoinInfo, bytes),
         true <- info.public_key == Params.public_params(params) do
      {:ok,
       %{
         title: State.attribute(params, info.title, :title),
         description: State.attribute(params, info.description, :description),
         avatar_key: if(info.avatar_key == "", do: nil, else: info.avatar_key),
         member_count: info.member_count,
         join_by_link: info.join_by_link,
         revision: info.revision,
         pending_approval: info.pending_approval
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Parses a `Content-Range: versions <a>-<b>/<c>` header of a 206 change log
  response (section 5.4) into `{a, b, c}`.
  """
  @spec content_range(String.t() | nil) :: {:ok, {integer(), integer(), integer()}} | :error
  def content_range("versions " <> range) do
    with [from, rest] <- String.split(range, "-", parts: 2),
         [to, current] <- String.split(rest, "/", parts: 2),
         {from, ""} <- Integer.parse(from),
         {to, ""} <- Integer.parse(to),
         {current, ""} <- Integer.parse(current) do
      {:ok, {from, to, current}}
    else
      _ -> :error
    end
  end

  def content_range(_header), do: :error

  @doc """
  Encodes the group context of a data message (section 9): the master key,
  the sender's revision and, for a group update, the signed change.
  """
  @spec encode_context(Params.t(), non_neg_integer(), binary() | nil) :: binary()
  def encode_context(%Params{master_key: key}, revision, signed_change \\ nil) do
    Protobuf.encode(%Wire.Context{
      master_key: key,
      revision: revision,
      group_change: signed_change
    })
  end

  @doc """
  Decodes a group context. The master key (32 bytes) and the revision are
  required (CRS-05 section 5.7); a context without either is invalid.
  """
  @spec decode_context(binary()) ::
          {:ok, %{master_key: <<_::256>>, revision: non_neg_integer(), change: binary() | nil}}
          | {:error, :invalid}
  def decode_context(bytes) do
    case State.decode(Wire.Context, bytes) do
      {:ok,
       %Wire.Context{
         master_key: <<_::binary-size(32)>> = key,
         revision: revision,
         group_change: change
       }}
      when is_integer(revision) ->
        {:ok, %{master_key: key, revision: revision, change: change}}

      _ ->
        {:error, :invalid}
    end
  end
end
