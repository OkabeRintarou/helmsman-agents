defmodule Helmsman.Repo.Migrations.AddAvatarIconsAndRuntimeVendor do
  use Ecto.Migration

  # `update-actor-icons` D1 and D10: an avatar is either an uploaded image
  # (the five image columns) or a built-in icon key (`icon`), never both;
  # a runtime keeps the vendor key its daemon reported.
  #
  # Rolling back deletes the icon avatars: the old schema has no place for
  # them (D1 accepts losing the chosen icons).

  @image_columns ~w(content_type data key byte_size edge)a

  def up do
    alter table(:avatars) do
      add :icon, :text
    end

    for column <- @image_columns do
      execute "ALTER TABLE avatars ALTER COLUMN #{column} DROP NOT NULL"
    end

    create constraint(:avatars, :avatars_icon_format, check: "icon ~ '^[a-z0-9]{1,32}$'")

    create constraint(:avatars, :avatars_form,
             check: """
             (icon IS NULL AND content_type IS NOT NULL AND data IS NOT NULL AND key IS NOT NULL \
             AND byte_size IS NOT NULL AND edge IS NOT NULL) OR \
             (icon IS NOT NULL AND content_type IS NULL AND data IS NULL AND key IS NULL \
             AND byte_size IS NULL AND edge IS NULL)\
             """
           )

    alter table(:runtimes) do
      add :vendor, :text
    end

    create constraint(:runtimes, :runtimes_vendor_format, check: "vendor ~ '^[a-z0-9]{1,32}$'")
  end

  def down do
    drop constraint(:runtimes, :runtimes_vendor_format)

    alter table(:runtimes) do
      remove :vendor
    end

    execute "DELETE FROM avatars WHERE icon IS NOT NULL"
    drop constraint(:avatars, :avatars_form)
    drop constraint(:avatars, :avatars_icon_format)

    for column <- @image_columns do
      execute "ALTER TABLE avatars ALTER COLUMN #{column} SET NOT NULL"
    end

    alter table(:avatars) do
      remove :icon
    end
  end
end
