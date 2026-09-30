defmodule SalixSignalProto.Group.State do
  @moduledoc """
  Decrypted group state (CRS-09b sections 4.2 to 4.5).

  Members, invitees, requesters and banned users are keyed by their 65-byte
  UID ciphertext. UID encryption is deterministic (CRS-09a section 7.3), so
  the ciphertext identifies a service ID within the group, and an entry
  whose ciphertext does not decrypt can still be matched (CRS-09b section
  6). `service_id` is the decrypted service ID or `nil`.

  Attribute blobs that fail to decrypt read as unset, as deployed clients
  treat them (section 4.5). Titles and descriptions are trimmed.

  Roles: `1` ordinary member, `2` administrator. Access levels: `1` anyone,
  `2` any member, `3` administrators only, `4` nobody. An absent access
  field reads as "any member" (2), except join by link, which reads as
  "nobody" (4) (section 4.4).
  """

  alias SalixSignalProto.Group.Blob
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Group.ProfileKey
  alias SalixSignalProto.Group.ProfileKeyCredential
  alias SalixSignalProto.Group.Uid
  alias SalixSignalProto.Group.Wire

  @role_member 1
  @role_admin 2
  @access_any_member 2
  @access_nobody 4

  defstruct revision: 0,
            title: nil,
            description: nil,
            avatar_key: nil,
            disappearing_timer: nil,
            access: %{attributes: 2, membership: 2, join_by_link: 4, member_labels: 2},
            members: [],
            invited: [],
            requesting: [],
            banned: [],
            invite_link_password: nil,
            announcements_only: false,
            terminated: false

  @type member :: %{
          uid: binary(),
          service_id: Uid.service_id() | nil,
          role: integer(),
          profile_key: ProfileKey.profile_key() | nil,
          joined_at_revision: non_neg_integer(),
          label_emoji: String.t() | nil,
          label_text: String.t() | nil
        }

  @type t :: %__MODULE__{}

  @doc "The role value of an administrator."
  def role_admin, do: @role_admin

  @doc "The role value of an ordinary member."
  def role_member, do: @role_member

  @doc """
  Decrypts a group state message (the protobuf bytes or the decoded
  `Wire.Group`). The state's public key must be the group's public params.
  """
  @spec decrypt(Params.t(), binary() | struct()) :: {:ok, t()} | {:error, :invalid}
  def decrypt(%Params{} = params, bytes) when is_binary(bytes) do
    case decode(Wire.Group, bytes) do
      {:ok, group} -> decrypt(params, group)
      error -> error
    end
  end

  def decrypt(%Params{} = params, %Wire.Group{} = g) do
    if g.public_key in ["", Params.public_params(params)] do
      {:ok,
       %__MODULE__{
         revision: g.revision,
         title: attribute(params, g.title, :title),
         description: attribute(params, g.description, :description),
         avatar_key: blank_to_nil(g.avatar_key),
         disappearing_timer: attribute(params, g.disappearing_timer, :disappearing_timer),
         access: access(g.access_control),
         members: Enum.flat_map(g.members, &List.wrap(member(params, &1, &1.joined_at_revision))),
         invited: Enum.flat_map(g.invited_members, &List.wrap(invited(params, &1))),
         requesting: Enum.flat_map(g.requesting_members, &List.wrap(requesting(params, &1))),
         banned: Enum.map(g.banned_members, &banned(params, &1)),
         invite_link_password: blank_to_nil(g.invite_link_password),
         announcements_only: g.announcements_only,
         terminated: g.terminated
       }}
    else
      {:error, :invalid}
    end
  end

  @doc false
  def decode(module, bytes) do
    {:ok, Protobuf.decode(bytes, module)}
  rescue
    _ -> {:error, :invalid}
  end

  @doc """
  Decrypts an attribute blob (CRS-09a section 9, CRS-09b section 4.5) and
  returns the value of `field`, or `nil` when it is empty, does not decrypt
  or holds another field.
  """
  @spec attribute(Params.t(), binary(), :title | :description | :disappearing_timer | :avatar) ::
          term()
  def attribute(_params, "", _field), do: nil

  def attribute(params, blob, field) do
    with {:ok, plaintext} <- Blob.decrypt(params, blob),
         {:ok, %Wire.AttributeBlob{content: {^field, value}}} <-
           decode(Wire.AttributeBlob, plaintext) do
      normalize(field, value)
    else
      _ -> nil
    end
  end

  defp normalize(field, value) when field in [:title, :description] do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(:disappearing_timer, 0), do: nil
  defp normalize(_field, value), do: value

  @doc "Encrypts an attribute blob holding one field."
  @spec encrypt_attribute(Params.t(), atom(), term(), keyword()) :: binary()
  def encrypt_attribute(params, field, value, opts \\ []) do
    plaintext = Protobuf.encode(%Wire.AttributeBlob{content: {field, value}})

    Blob.encrypt(
      params,
      plaintext,
      0,
      Keyword.get(opts, :randomness, :crypto.strong_rand_bytes(32))
    )
  end

  @doc "Decrypts a member label blob (raw UTF-8, CRS-09b section 4.3)."
  @spec label(Params.t(), binary()) :: String.t() | nil
  def label(_params, ""), do: nil

  def label(params, blob) do
    case Blob.decrypt(params, blob) do
      {:ok, ""} -> nil
      {:ok, text} -> if String.valid?(text), do: text, else: nil
      {:error, _} -> nil
    end
  end

  defp access(nil), do: access(%Wire.AccessControl{})

  defp access(%Wire.AccessControl{} = a) do
    %{
      attributes: default(a.attributes, @access_any_member),
      membership: default(a.membership, @access_any_member),
      join_by_link: default(a.join_by_link, @access_nobody),
      member_labels: default(a.member_labels, @access_any_member)
    }
  end

  defp default(0, value), do: value
  defp default(level, _value), do: level

  @doc """
  Decodes a full member record into a member entry. The UID and profile key
  ciphertexts come from the presentation in field 4 when it is present, and
  otherwise from fields 1 and 3 (CRS-09b section 4.3). Returns `nil` for a
  record with neither.
  """
  @spec member(Params.t(), struct(), non_neg_integer()) :: member() | nil
  def member(params, %Wire.Member{} = m, joined_at_revision) do
    case ciphertexts(m.user_id, m.profile_key, m.presentation) do
      {:ok, uid, profile_key_ciphertext} ->
        service_id = decrypt_uid(params, uid)

        %{
          uid: uid,
          service_id: service_id,
          role: m.role,
          profile_key: decrypt_profile_key(params, profile_key_ciphertext, service_id),
          joined_at_revision: joined_at_revision,
          label_emoji: label(params, m.label_emoji),
          label_text: label(params, m.label_text)
        }

      :error ->
        nil
    end
  end

  # CRS-09b section 4.3: a present presentation is the source of the UID
  # and profile key ciphertexts; the ciphertext fields apply only without
  # one. A presentation that does not parse makes the record invalid.
  @doc false
  def ciphertexts(uid, profile_key, presentation) do
    cond do
      presentation != "" ->
        case ProfileKeyCredential.ciphertexts(presentation) do
          {:ok, {uid, profile_key}} -> {:ok, uid, profile_key}
          {:error, _} -> :error
        end

      uid != "" ->
        {:ok, uid, profile_key}

      true ->
        :error
    end
  end

  @doc false
  def decrypt_uid(params, uid) do
    case Uid.decrypt(params, uid) do
      {:ok, service_id} -> service_id
      {:error, _} -> nil
    end
  end

  @doc false
  def decrypt_profile_key(params, ciphertext, {:aci, uuid}) when ciphertext != "" do
    case ProfileKey.decrypt(params, ciphertext, uuid) do
      {:ok, key} -> key
      {:error, _} -> nil
    end
  end

  def decrypt_profile_key(_params, _ciphertext, _service_id), do: nil

  @doc false
  def invited(params, %Wire.InvitedMember{member: %Wire.Member{user_id: uid, role: role}} = i)
      when uid != "" do
    %{
      uid: uid,
      service_id: decrypt_uid(params, uid),
      role: role,
      added_by: i.added_by,
      added_by_service_id: if(i.added_by != "", do: decrypt_uid(params, i.added_by)),
      timestamp: i.timestamp
    }
  end

  def invited(_params, _record), do: nil

  @doc false
  def requesting(params, %Wire.RequestingMember{} = r) do
    case ciphertexts(r.user_id, r.profile_key, r.presentation) do
      {:ok, uid, profile_key_ciphertext} ->
        service_id = decrypt_uid(params, uid)

        %{
          uid: uid,
          service_id: service_id,
          profile_key: decrypt_profile_key(params, profile_key_ciphertext, service_id),
          timestamp: r.timestamp
        }

      :error ->
        nil
    end
  end

  @doc false
  def banned(params, %Wire.BannedMember{user_id: uid, timestamp: timestamp}),
    do: %{uid: uid, service_id: decrypt_uid(params, uid), timestamp: timestamp}

  @doc "The full member with this service ID, or nil."
  @spec find_member(t(), Params.t(), Uid.service_id()) :: member() | nil
  def find_member(%__MODULE__{members: members}, params, service_id) do
    uid = Uid.encrypt(params, service_id)
    Enum.find(members, &(&1.uid == uid))
  end

  @doc "The service IDs of all full members whose ciphertext decrypted."
  @spec member_service_ids(t()) :: [Uid.service_id()]
  def member_service_ids(%__MODULE__{members: members}),
    do: for(%{service_id: id} <- members, id != nil, do: id)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
