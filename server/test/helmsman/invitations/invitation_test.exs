defmodule Helmsman.Invitations.InvitationTest do
  use Helmsman.DataCase, async: true

  alias Helmsman.Invitations.Invitation

  defp changeset(attrs) do
    Invitation.create_changeset(
      %Invitation{
        workspace_id: 1,
        invited_by_id: 1,
        token_hash: <<0::256>>,
        expires_at: DateTime.utc_now(:second)
      },
      attrs
    )
  end

  test "email is optional; blank means a generic link" do
    for attrs <- [%{role: :member}, %{role: :member, email: ""}, %{role: :member, email: "  "}] do
      changeset = changeset(attrs)
      assert changeset.valid?
      assert get_field(changeset, :email) == nil
    end
  end

  test "email is trimmed and downcased" do
    changeset = changeset(%{"role" => "admin", "email" => "  Bob@X.com "})
    assert changeset.valid?
    assert get_field(changeset, :email) == "bob@x.com"
    assert get_field(changeset, :role) == :admin
  end

  test "rejects malformed emails" do
    assert %{email: [_]} = errors_on(changeset(%{role: :member, email: "bob at x"}))
  end

  test "role is required and must be a known role" do
    assert %{role: ["can't be blank"]} = errors_on(changeset(%{}))
    assert %{role: ["is invalid"]} = errors_on(changeset(%{role: "guest"}))
  end

  test "the token hash is redacted" do
    refute inspect(%Invitation{token_hash: "secret-hash"}) =~ "secret-hash"
  end
end
