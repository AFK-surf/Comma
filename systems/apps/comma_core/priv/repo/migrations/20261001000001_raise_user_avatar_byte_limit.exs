defmodule Comma.Repo.Migrations.RaiseUserAvatarByteLimit do
  use Ecto.Migration

  def up do
    drop(constraint(:comma_user_avatars, :comma_user_avatars_byte_size_valid))

    create(
      constraint(:comma_user_avatars, :comma_user_avatars_byte_size_valid,
        check: "byte_size > 0 AND byte_size <= 2097152"
      )
    )
  end

  def down do
    # Rows above the old bound would violate the restored constraint.
    drop(constraint(:comma_user_avatars, :comma_user_avatars_byte_size_valid))

    create(
      constraint(:comma_user_avatars, :comma_user_avatars_byte_size_valid,
        check: "byte_size > 0 AND byte_size <= 102400"
      )
    )
  end
end
