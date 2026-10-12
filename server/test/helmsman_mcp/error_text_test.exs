defmodule HelmsmanMCP.ErrorTextTest do
  use ExUnit.Case, async: true

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Workspaces.Workspace
  alias HelmsmanMCP.{Context, ErrorText}

  defp ctx(args \\ %{}, role \\ :viewer) do
    %Context{
      tool: "identify",
      args: args,
      scope: %Scope{role: role, workspace: %Workspace{slug: "acme"}}
    }
  end

  defp changeset do
    %Actor{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:name, "must be at most %{count} characters", count: 64)
    |> Ecto.Changeset.add_error(:worktree, "is invalid")
  end

  @cases [
    {"viewer", :forbidden, {%{}, :viewer}, "Your role (viewer) cannot do this."},
    {"no role", :forbidden, {%{}, nil}, "You cannot do this."},
    {"forbidden actor", :forbidden, {%{"actor" => "bob/dev"}, :member},
     "Your role (member) cannot do this. The actor argument must name an agent of your own."},
    {"not found", :not_found, {%{}, :viewer}, "Not found in workspace acme."},
    {"name taken", :name_taken, {%{"name" => "alice"}, :viewer},
     "The name alice belongs to a human or to someone else's agent. " <>
       "Pick another agent name, such as team/role (e.g. keel/dev)."},
    {"disabled by name", {:agent_disabled, "keel/dev"}, {%{}, :viewer},
     "The agent keel/dev is disabled. Call identify with another agent name, " <>
       "or ask a human to enable it."},
    {"disabled identify", :agent_disabled, {%{"name" => "keel/dev"}, :viewer},
     "The agent keel/dev is disabled. Call identify with another agent name, " <>
       "or ask a human to enable it."},
    {"invalid kind", {:invalid_kind, "human"}, {%{}, :viewer}, "Only kind=agent is supported."}
  ]

  for {label, reason, {args, role}, text} <- @cases do
    test label do
      ctx = ctx(unquote(Macro.escape(args)), unquote(role))
      assert ErrorText.format(unquote(Macro.escape(reason)), ctx) == {:ok, unquote(text)}
    end
  end

  test "a changeset lists one field per line" do
    assert ErrorText.format(changeset(), ctx()) ==
             {:ok, "name: must be at most 64 characters\nworktree: is invalid"}
  end

  test "an unknown reason has no text" do
    assert ErrorText.format(:whatever, ctx()) == :error
  end

  test "the internal error text carries the reference" do
    assert ErrorText.internal("0a1b2c3d") ==
             "Internal error (ref 0a1b2c3d). Try again later; if it keeps happening, tell a human."
  end

  test "every text is ASCII" do
    texts =
      [ErrorText.internal("0a1b2c3d") | Enum.map(@cases, &elem(&1, 3))] ++
        [elem(ErrorText.format(changeset(), ctx()), 1)]

    for text <- texts, do: assert(text =~ ~r/\A[\x20-\x7e\n]+\z/)
  end
end
