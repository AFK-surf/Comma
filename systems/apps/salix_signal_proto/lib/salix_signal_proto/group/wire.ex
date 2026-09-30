# Protocol-buffer messages of the storage-service group API (CRS-09b section
# 4). They are proto3: fields with default values are omitted on the wire.
# Field names are the CRS's descriptive names. Enumerations (role, access
# level) are carried as int32 values.

defmodule SalixSignalProto.Group.Wire.Member do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:user_id, 1, type: :bytes)
  field(:role, 2, type: :int32)
  field(:profile_key, 3, type: :bytes)
  field(:presentation, 4, type: :bytes)
  field(:joined_at_revision, 5, type: :uint32)
  field(:label_emoji, 6, type: :bytes)
  field(:label_text, 7, type: :bytes)
end

defmodule SalixSignalProto.Group.Wire.InvitedMember do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:member, 1, type: SalixSignalProto.Group.Wire.Member)
  field(:added_by, 2, type: :bytes)
  field(:timestamp, 3, type: :uint64)
end

defmodule SalixSignalProto.Group.Wire.RequestingMember do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:user_id, 1, type: :bytes)
  field(:profile_key, 2, type: :bytes)
  field(:presentation, 3, type: :bytes)
  field(:timestamp, 4, type: :uint64)
end

defmodule SalixSignalProto.Group.Wire.BannedMember do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:user_id, 1, type: :bytes)
  field(:timestamp, 2, type: :uint64)
end

defmodule SalixSignalProto.Group.Wire.AccessControl do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:attributes, 1, type: :int32)
  field(:membership, 2, type: :int32)
  field(:join_by_link, 3, type: :int32)
  field(:member_labels, 4, type: :int32)
end

defmodule SalixSignalProto.Group.Wire.Group do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:public_key, 1, type: :bytes)
  field(:title, 2, type: :bytes)
  field(:avatar_key, 3, type: :string)
  field(:disappearing_timer, 4, type: :bytes)
  field(:access_control, 5, type: SalixSignalProto.Group.Wire.AccessControl)
  field(:revision, 6, type: :uint32)
  field(:members, 7, repeated: true, type: SalixSignalProto.Group.Wire.Member)
  field(:invited_members, 8, repeated: true, type: SalixSignalProto.Group.Wire.InvitedMember)

  field(:requesting_members, 9,
    repeated: true,
    type: SalixSignalProto.Group.Wire.RequestingMember
  )

  field(:invite_link_password, 10, type: :bytes)
  field(:description, 11, type: :bytes)
  field(:announcements_only, 12, type: :bool)
  field(:banned_members, 13, repeated: true, type: SalixSignalProto.Group.Wire.BannedMember)
  field(:terminated, 14, type: :bool)
end

defmodule SalixSignalProto.Group.Wire.AttributeBlob do
  @moduledoc false
  use Protobuf, syntax: :proto3

  oneof(:content, 0)

  field(:title, 1, type: :string, oneof: 0)
  field(:avatar, 2, type: :bytes, oneof: 0)
  field(:disappearing_timer, 3, type: :uint32, oneof: 0)
  field(:description, 4, type: :string, oneof: 0)
end

defmodule SalixSignalProto.Group.Wire.SignedChange do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:actions, 1, type: :bytes)
  field(:server_signature, 2, type: :bytes)
  field(:change_epoch, 3, type: :uint32)
end

defmodule SalixSignalProto.Group.Wire.Actions do
  @moduledoc false
  use Protobuf, syntax: :proto3

  defmodule AddMember do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:added, 1, type: SalixSignalProto.Group.Wire.Member)
    field(:joined_by_link, 2, type: :bool)
  end

  defmodule UserId do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:user_id, 1, type: :bytes)
  end

  defmodule ChangeRole do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:user_id, 1, type: :bytes)
    field(:role, 2, type: :int32)
  end

  defmodule PresentationUpdate do
    @moduledoc false
    # Update profile keys (6) and accept invitations (9).
    use Protobuf, syntax: :proto3
    field(:presentation, 1, type: :bytes)
    field(:user_id, 2, type: :bytes)
    field(:profile_key, 3, type: :bytes)
  end

  defmodule AddInvitedMember do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:added, 1, type: SalixSignalProto.Group.Wire.InvitedMember)
  end

  defmodule AddRequestingMember do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:added, 1, type: SalixSignalProto.Group.Wire.RequestingMember)
  end

  defmodule AddBannedMember do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:added, 1, type: SalixSignalProto.Group.Wire.BannedMember)
  end

  defmodule BytesValue do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:value, 1, type: :bytes)
  end

  defmodule StringValue do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:value, 1, type: :string)
  end

  defmodule AccessValue do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:value, 1, type: :int32)
  end

  defmodule BoolValue do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:value, 1, type: :bool)
  end

  defmodule AcceptPniInvitation do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:presentation, 1, type: :bytes)
    field(:aci_user_id, 2, type: :bytes)
    field(:pni_user_id, 3, type: :bytes)
    field(:profile_key, 4, type: :bytes)
  end

  defmodule ChangeMemberLabel do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:user_id, 1, type: :bytes)
    field(:label_emoji, 2, type: :bytes)
    field(:label_text, 3, type: :bytes)
  end

  defmodule Empty do
    @moduledoc false
    use Protobuf, syntax: :proto3
  end

  alias __MODULE__, as: A

  field(:editor, 1, type: :bytes)
  field(:revision, 2, type: :uint32)
  field(:add_members, 3, repeated: true, type: A.AddMember)
  field(:remove_members, 4, repeated: true, type: A.UserId)
  field(:change_roles, 5, repeated: true, type: A.ChangeRole)
  field(:update_profile_keys, 6, repeated: true, type: A.PresentationUpdate)
  field(:add_invited_members, 7, repeated: true, type: A.AddInvitedMember)
  field(:remove_invited_members, 8, repeated: true, type: A.UserId)
  field(:accept_invitations, 9, repeated: true, type: A.PresentationUpdate)
  field(:change_title, 10, type: A.BytesValue)
  field(:change_avatar, 11, type: A.StringValue)
  field(:change_timer, 12, type: A.BytesValue)
  field(:change_attributes_access, 13, type: A.AccessValue)
  field(:change_membership_access, 14, type: A.AccessValue)
  field(:change_join_by_link_access, 15, type: A.AccessValue)
  field(:add_requesting_members, 16, repeated: true, type: A.AddRequestingMember)
  field(:remove_requesting_members, 17, repeated: true, type: A.UserId)
  field(:approve_requesting_members, 18, repeated: true, type: A.ChangeRole)
  field(:change_link_password, 19, type: A.BytesValue)
  field(:change_description, 20, type: A.BytesValue)
  field(:change_announcements_only, 21, type: A.BoolValue)
  field(:ban_members, 22, repeated: true, type: A.AddBannedMember)
  field(:unban_members, 23, repeated: true, type: A.UserId)
  field(:accept_pni_invitations, 24, repeated: true, type: A.AcceptPniInvitation)
  field(:group_id, 25, type: :bytes)
  field(:change_member_labels, 26, repeated: true, type: A.ChangeMemberLabel)
  field(:change_member_label_access, 27, type: A.AccessValue)
  field(:terminate_group, 28, type: A.Empty)
end

defmodule SalixSignalProto.Group.Wire.GroupResponse do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:group, 1, type: SalixSignalProto.Group.Wire.Group)
  field(:endorsements, 2, type: :bytes)
end

defmodule SalixSignalProto.Group.Wire.ChangeResponse do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:change, 1, type: SalixSignalProto.Group.Wire.SignedChange)
  field(:endorsements, 2, type: :bytes)
end

defmodule SalixSignalProto.Group.Wire.ChangeLog do
  @moduledoc false
  use Protobuf, syntax: :proto3

  defmodule Entry do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:change, 1, type: SalixSignalProto.Group.Wire.SignedChange)
    field(:state, 2, type: SalixSignalProto.Group.Wire.Group)
  end

  field(:entries, 1, repeated: true, type: Entry)
  field(:endorsements, 2, type: :bytes)
end

defmodule SalixSignalProto.Group.Wire.JoinInfo do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:public_key, 1, type: :bytes)
  field(:title, 2, type: :bytes)
  field(:avatar_key, 3, type: :string)
  field(:member_count, 4, type: :uint32)
  field(:join_by_link, 5, type: :int32)
  field(:revision, 6, type: :uint32)
  field(:pending_approval, 7, type: :bool)
  field(:description, 8, type: :bytes)
end

defmodule SalixSignalProto.Group.Wire.ExternalCredential do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:token, 1, type: :string)
end

defmodule SalixSignalProto.Group.Wire.AvatarUploadForm do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:key, 1, type: :string)
  field(:credential, 2, type: :string)
  field(:acl, 3, type: :string)
  field(:algorithm, 4, type: :string)
  field(:date, 5, type: :string)
  field(:policy, 6, type: :string)
  field(:signature, 7, type: :string)
end

defmodule SalixSignalProto.Group.Wire.InviteLink do
  @moduledoc false
  use Protobuf, syntax: :proto3

  defmodule V1 do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:master_key, 1, type: :bytes)
    field(:password, 2, type: :bytes)
  end

  field(:v1, 1, type: V1)
end

defmodule SalixSignalProto.Group.Wire.Context do
  @moduledoc false
  # Group context, field 15 of the data message (CRS-09b section 9). proto2,
  # like the data message that carries it.
  use Protobuf, syntax: :proto2

  field(:master_key, 1, optional: true, type: :bytes)
  field(:revision, 2, optional: true, type: :uint32)
  field(:group_change, 3, optional: true, type: :bytes)
end
