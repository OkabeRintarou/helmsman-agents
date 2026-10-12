defmodule Helmsman.Agents.AgentProfileTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile

  setup do
    user = user_fixture()
    workspace = workspace_fixture(user)

    %{
      actor: %Actor{workspace_id: workspace.id, owner_id: user.id, kind: :agent},
      profile: %AgentProfile{workspace_id: workspace.id}
    }
  end

  for {field, values} <- [
        provider: [nil, "unknown"],
        access: [nil, "everyone"],
        max_concurrency: [0, 17],
        timeout_minutes: [0, 1201],
        idle_timeout_minutes: [0, 241, 121],
        model: [String.duplicate("m", 129)],
        effort: [String.duplicate("e", 129)],
        description: [String.duplicate("文", 1001)],
        instructions: [String.duplicate("x", 65_537)],
        custom_args: [List.duplicate("arg", 65), [""], [String.duplicate("x", 4097)]],
        capabilities: [["delegate"]],
        env: [
          %{"1A" => "secret"},
          %{"A-B" => "secret"},
          %{"HELMSMAN_X" => "secret"},
          %{"Helmsman_x" => "secret"},
          %{String.duplicate("A", 129) => "secret"},
          %{"A" => String.duplicate("x", 8193)},
          Map.new(1..65, &{"A#{&1}", "x"}),
          %{"A" => 1}
        ],
        extra_mcp_servers: [%{"Helmsman" => %{}}, %{"other" => String.duplicate("x", 32_769)}]
      ],
      value <- values do
    test "rejects #{field}: #{inspect(value, limit: 2)}", ctx do
      cs =
        AgentProfile.changeset(
          ctx.profile,
          Map.put(%{provider: "claude"}, unquote(field), unquote(Macro.escape(value))),
          ctx.actor
        )

      refute cs.valid?
      assert unquote(field) in Keyword.keys(cs.errors)
    end
  end

  test "accepts every field at its allowed limits and empty optional fields", ctx do
    cs =
      AgentProfile.changeset(
        ctx.profile,
        %{
          provider: "claude",
          access: "workspace",
          model: "",
          effort: "",
          max_concurrency: 16,
          timeout_minutes: 1200,
          idle_timeout_minutes: 240,
          instructions: String.duplicate("x", 65_536),
          description: String.duplicate("文", 1000),
          custom_args: List.duplicate(String.duplicate("x", 4096), 64),
          env: %{String.duplicate("A", 128) => String.duplicate("x", 8192)},
          extra_mcp_servers: %{"custom" => %{"command" => "tool"}},
          capabilities: ["create_tasks"]
        },
        ctx.actor
      )

    assert cs.valid?, inspect(cs.errors)
    assert get_field(cs, :model) == nil
    assert get_field(cs, :effort) == nil
  end

  test "member access rejects viewers and nonmembers, deduplicates current members", ctx do
    viewer = user_fixture()
    member = user_fixture()
    stranger = user_fixture()
    workspace = Repo.get!(Helmsman.Workspaces.Workspace, ctx.actor.workspace_id)
    member_fixture(workspace, viewer, :viewer)
    member_fixture(workspace, member, :member)

    for id <- [viewer.id, stranger.id] do
      cs =
        AgentProfile.changeset(
          ctx.profile,
          %{provider: "claude", access: "members", access_member_ids: [id]},
          ctx.actor
        )

      assert :access_member_ids in Keyword.keys(cs.errors)
    end

    cs =
      AgentProfile.changeset(
        ctx.profile,
        %{provider: "claude", access: "members", access_member_ids: [member.id, member.id]},
        ctx.actor
      )

    assert cs.valid?
    assert get_field(cs, :access_member_ids) == [member.id]

    cs =
      AgentProfile.changeset(
        ctx.profile,
        %{provider: "claude", access_member_ids: [stranger.id]},
        ctx.actor
      )

    assert get_field(cs, :access_member_ids) == []
  end
end
