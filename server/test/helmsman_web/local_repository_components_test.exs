defmodule HelmsmanWeb.LocalRepositoryComponentsTest do
  @moduledoc "add-local-repositories-ui D3 (status and reasons), D6 (chip), D7 (review commands)."
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HelmsmanWeb.LocalRepositoryComponents, as: C

  defp repo(attrs) do
    Map.merge(
      %{
        id: 1,
        name: "app",
        daemon_id: 1,
        daemon_name: "alice-mbp",
        owner: %{user_id: 1, name: "alice"},
        status: "online",
        unavailable_reason: nil,
        default_branch: "main",
        removed: false,
        path: "/home/alice/code/app"
      },
      Map.new(attrs)
    )
  end

  # D3: {attrs, status, tone class, label, note (nil = none)}
  @rows [
    {%{status: "online"}, "online", "tint-success", "可用", nil},
    {%{status: "offline"}, "offline", "bg-hover", "机器离线", "所在机器离线，运行会等它上线后执行"},
    {%{status: "unavailable", unavailable_reason: "not configured on the machine"}, "unavailable",
     "tint-warning", "不可用", "机器上已不再配置"},
    {%{
       status: "unavailable",
       unavailable_reason: "not shared with this workspace on the machine"
     }, "unavailable", "tint-warning", "不可用", "机器上已不再对本工作区开放"},
    {%{status: "unavailable", unavailable_reason: "duplicate name on the machine"}, "unavailable",
     "tint-warning", "不可用", "机器上有重名的登记"},
    {%{status: "unavailable", unavailable_reason: "not a git repository"}, "unavailable",
     "tint-warning", "不可用", "机器报告：not a git repository"},
    {%{status: "online", removed: true}, "removed", "tint-danger", "已移除",
     "该本地仓库已从工作区移除，绑定它的项目无法执行运行"}
  ]

  for {{attrs, status, tone, label, note}, i} <- Enum.with_index(@rows) do
    test "status row #{i}: #{status} #{label}" do
      repository = repo(unquote(Macro.escape(attrs)))
      html = render_component(&C.status_badge/1, id: "s", repository: repository)

      assert html =~ ~s(data-status="#{unquote(status)}")
      assert html =~ unquote(tone)
      assert html =~ unquote(label)
      note = unquote(note)
      assert C.status_note(repository) == note
      assert shows_note?(html, note)
    end
  end

  defp shows_note?(_html, nil), do: true
  defp shows_note?(html, note), do: html =~ note

  describe "reason_text/1" do
    test "translates the fixed reasons" do
      assert C.reason_text("not configured on the machine") == {:translated, "机器上已不再配置"}

      assert C.reason_text("not shared with this workspace on the machine") ==
               {:translated, "机器上已不再对本工作区开放"}

      assert C.reason_text("duplicate name on the machine") == {:translated, "机器上有重名的登记"}
    end

    test "keeps any other reason as reported, and nil" do
      assert C.reason_text("not a git repository") == {:reported, "not a git repository"}
      assert C.reason_text(nil) == nil
    end

    test "a reported reason is shown inline in English after the prefix" do
      html =
        render_component(&C.status_badge/1,
          id: "s",
          repository: repo(status: "unavailable", unavailable_reason: "not a git repository"),
          reason: true
        )

      assert html =~ "机器报告："
      assert html =~ ~s(<span lang="en">not a git repository</span>)
    end

    test "an unknown status is neutral" do
      html = render_component(&C.status_badge/1, id: "s", repository: repo(status: "weird"))
      assert html =~ ~s(data-status="unknown")
      assert html =~ "未知"
    end
  end

  describe "local_repo_chip/1" do
    test "name, machine and branch; no warning when available" do
      html =
        render_component(&C.local_repo_chip/1, id: "c", repository: repo(%{}), branch: "main")

      assert html =~ "app"
      assert html =~ "· alice-mbp"
      assert html =~ "→"
      assert html =~ "main"
      refute html =~ "data-unavailable"
      refute html =~ "/home/alice"
    end

    test "a warning with the explanation when not available" do
      html =
        render_component(&C.local_repo_chip/1, id: "c", repository: repo(status: "offline"))

      assert html =~ ~s(data-status="offline")
      assert html =~ "data-unavailable"
      assert html =~ "所在机器离线，运行会等它上线后执行"
    end
  end

  describe "local_branch_card/1" do
    defp branch(state) do
      %{
        branch: "hm/7/bos-12",
        head_sha: String.duplicate("a1b2c3d4", 5),
        state: state,
        merged_at: ~U[2026-10-13 08:00:00Z],
        merged_by: nil,
        merge_note: nil,
        base_branch: "main",
        updated_at: ~U[2026-10-13 07:00:00Z],
        local_repository: repo(%{})
      }
    end

    defp state_badge(html),
      do: html |> LazyHTML.from_fragment() |> LazyHTML.query("#task-local-branch-state > span")

    test "已合并 takes the PR card's 已合并 tone (4.2)" do
      %{tone: tone} = HelmsmanWeb.GitHubComponents.pr_state("merged")
      assert tone == :review

      html = render_component(&C.local_branch_card/1, branch: branch("merged"))
      badge = state_badge(html)

      assert LazyHTML.attribute(badge, "data-tone") == ["review"]
      assert [class] = LazyHTML.attribute(badge, "class")
      assert class =~ "text-review-fg"
      assert class =~ "tint-review"
      assert LazyHTML.text(badge) =~ "已合并"
    end

    test "未合并 stays muted" do
      html = render_component(&C.local_branch_card/1, branch: branch("open"))
      badge = state_badge(html)

      assert LazyHTML.text(badge) =~ "未合并"
      refute LazyHTML.attribute(badge, "class") |> hd() =~ "review"
    end
  end

  describe "review_commands/2" do
    @branch %{branch: "hm/7/bos-12", base_branch: "main", state: "open"}

    defp commands(branch, path),
      do: branch |> C.review_commands(path) |> Map.new(&{&1.id, &1.command})

    test "with the path" do
      assert commands(@branch, "/home/alice/code/app") == %{
               log: "git -C /home/alice/code/app log --oneline main..hm/7/bos-12",
               diff: "git -C /home/alice/code/app diff main...hm/7/bos-12",
               merge:
                 "git -C /home/alice/code/app switch main && " <>
                   "git -C /home/alice/code/app merge --no-ff hm/7/bos-12"
             }
    end

    test "without the path" do
      assert commands(@branch, nil) == %{
               log: "git log --oneline main..hm/7/bos-12",
               diff: "git diff main...hm/7/bos-12",
               merge: "git switch main && git merge --no-ff hm/7/bos-12"
             }
    end

    test "quotes spaces and single quotes" do
      cmds = commands(%{@branch | base_branch: "it's main"}, "/home/a b/it's")

      assert cmds.log ==
               ~S(git -C '/home/a b/it'\''s' log --oneline 'it'\''s main'..hm/7/bos-12)

      assert cmds.merge ==
               ~S(git -C '/home/a b/it'\''s' switch 'it'\''s main' && ) <>
                 ~S(git -C '/home/a b/it'\''s' merge --no-ff hm/7/bos-12)
    end

    test "a merged branch has only the log and diff commands, in order" do
      assert @branch |> Map.put(:state, "merged") |> C.review_commands(nil) |> Enum.map(& &1.id) ==
               [:log, :diff]

      assert @branch |> C.review_commands(nil) |> Enum.map(& &1.id) == [:log, :diff, :merge]
    end

    test "no commands without a base branch" do
      assert C.review_commands(%{@branch | base_branch: nil}, "/p") == nil
    end

    test "shell_quote/1" do
      assert C.shell_quote("main") == "main"
      assert C.shell_quote("") == "''"
      assert C.shell_quote("a;rm -rf") == "'a;rm -rf'"
      assert C.shell_quote("$(x)") == "'$(x)'"
      assert C.shell_quote("~/x") == "'~/x'"
    end
  end
end
