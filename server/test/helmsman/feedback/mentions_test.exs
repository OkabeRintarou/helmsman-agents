defmodule Helmsman.Feedback.MentionsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Feedback.Mentions

  doctest Mentions

  @long String.duplicate("a", 64)

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)

    ids =
      for name <- ["alice", "keel/dev", "bob", @long],
          into: %{},
          do: {name, agent!(workspace, owner, name)}

    other = workspace_fixture(user_fixture())
    agent_fixture(other, owner, "carol")
    %{workspace: workspace, ids: ids}
  end

  defp agent!(workspace, owner, name), do: agent_fixture(workspace, owner, name).id

  defp mentions(workspace, content), do: Mentions.resolve(workspace.id, Mentions.extract(content))

  defp ids(ctx, names), do: Enum.map(names, &Map.fetch!(ctx.ids, &1))

  describe "the spec scenarios" do
    test "plain mentions, trailing punctuation dropped", ctx do
      assert mentions(ctx.workspace, "@keel/dev 请看一下，cc @alice.") ==
               ids(ctx, ["keel/dev", "alice"])
    end

    test "@ in code mentions no one", ctx do
      assert mentions(ctx.workspace, "运行 `npm i @types/node`\n\n```\n@alice\n```\n") == []
      assert mentions(ctx.workspace, "    @alice indented code\n") == []
    end

    test "unknown names are ignored", ctx do
      assert mentions(ctx.workspace, "@nobody 你好") == []
      assert mentions(ctx.workspace, "@carol of another workspace") == []
    end
  end

  describe "long names (review R1)" do
    test "exactly 64 characters mention the identity", ctx do
      assert mentions(ctx.workspace, "hi @#{@long}") == ids(ctx, [@long])
      assert mentions(ctx.workspace, "hi @#{@long}.") == ids(ctx, [@long])
    end

    test "65 and 80 characters with the same prefix mention no one", ctx do
      assert mentions(ctx.workspace, "hi @#{@long}a") == []
      assert mentions(ctx.workspace, "hi @#{@long}#{String.duplicate("b", 16)} there") == []
    end

    test "too long even without the trailing period", ctx do
      assert mentions(ctx.workspace, "hi @#{@long}a.") == []
      assert mentions(ctx.workspace, "hi @#{@long}a/-.") == []
    end

    test "a name that is not an identity name is never cut down", ctx do
      assert mentions(ctx.workspace, "@alice_x") == []
      assert mentions(ctx.workspace, "@alice/ok") == []
    end
  end

  describe "what is not a mention" do
    test "link text, image alt and raw HTML", ctx do
      assert mentions(ctx.workspace, "see [@alice](https://x)") == []
      assert mentions(ctx.workspace, "![@alice](a.png)") == []
      assert mentions(ctx.workspace, "<div>@alice</div>\n") == []
      assert mentions(ctx.workspace, "<span title=\"@alice\">x</span>") == []
    end

    test "e-mail addresses and @ inside a word", ctx do
      assert mentions(ctx.workspace, "write to bob@alice.com") == []
      assert mentions(ctx.workspace, "foo@alice") == []
      assert mentions(ctx.workspace, "@@alice") == []
    end
  end

  describe "what is a mention" do
    test "trailing punctuation is dropped", ctx do
      assert mentions(ctx.workspace, "thanks @alice, and @keel/dev/") ==
               ids(ctx, ["alice", "keel/dev"])

      assert mentions(ctx.workspace, "(@alice)") == ids(ctx, ["alice"])
    end

    test "names are case-insensitive", ctx do
      assert mentions(ctx.workspace, "@Alice and @KEEL/Dev") == ids(ctx, ["alice", "keel/dev"])
    end

    test "each identity once, in order of appearance", ctx do
      assert mentions(ctx.workspace, "@bob @alice @bob @ALICE @alice.") ==
               ids(ctx, ["bob", "alice"])
    end

    test "in emphasis, lists, quotes, tables and across lines", ctx do
      content = """
      **@alice** and _@bob_

      - item @keel/dev

      > @alice

      | a | b |
      |---|---|
      | @bob | x |

      line one
      @alice
      """

      assert mentions(ctx.workspace, content) == ids(ctx, ["alice", "bob", "keel/dev"])
    end

    test "text after a code span still counts", ctx do
      assert mentions(ctx.workspace, "`x` @alice") == ids(ctx, ["alice"])
    end
  end

  describe "resolve/2" do
    test "one query for every candidate, none without candidates", ctx do
      handler = "mentions-#{System.unique_integer()}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:helmsman, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test_pid, do: send(test_pid, {:query, meta.source})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert Mentions.resolve(ctx.workspace.id, ["alice", "bob.", "keel/dev/", "nobody"]) ==
               ids(ctx, ["alice", "bob", "keel/dev"])

      assert_received {:query, "actors"}
      refute_received {:query, _}

      assert Mentions.resolve(ctx.workspace.id, []) == []
      refute_received {:query, _}
    end

    test "the longest variant wins", ctx do
      owner = Repo.get_by!(Actor, id: ctx.ids["alice"]).owner_id
      dotted = agent_fixture(ctx.workspace, %{id: owner}, "alice.").id
      assert Mentions.resolve(ctx.workspace.id, ["alice."]) == [dotted]
      assert Mentions.resolve(ctx.workspace.id, ["alice.."]) == [dotted]
    end
  end
end
