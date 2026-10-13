defmodule Helmsman.Backup.SchemasTest do
  use Helmsman.DataCase, async: true
  alias Helmsman.Actors.Claim
  alias Helmsman.Backup.{ExportRecord, ImportRecord}

  test "job enums, lengths and required fields reject malformed audit records" do
    assert ExportRecord.changeset(%ExportRecord{}, %{workspace_id: 1, user_id: 1, status: :queued}).valid?

    refute ExportRecord.changeset(%ExportRecord{}, %{
             workspace_id: 1,
             user_id: 1,
             status: :unknown
           }).valid?

    refute ExportRecord.changeset(%ExportRecord{}, %{
             workspace_id: 1,
             user_id: 1,
             file: String.duplicate("x", 256),
             sha256: "short",
             size: -1
           }).valid?

    for {field, value} <- [
          mode: :unknown,
          source: :unknown,
          status: :unknown,
          file_name: String.duplicate("x", 256),
          upload: String.duplicate("x", 256),
          file_sha256: "short",
          errors: List.duplicate(%{}, 101)
        ] do
      refute ImportRecord.changeset(%ImportRecord{workspace_id: 1}, %{field => value}).valid?
    end

    for status <- [:pending, :approved, :rejected, :cancelled] do
      assert Claim.changeset(%Claim{}, %{workspace_id: 1, actor_id: 1, user_id: 1, status: status}).valid?
    end

    refute Claim.changeset(%Claim{}, %{status: :unknown}).valid?
  end
end
