defmodule HelmsmanWeb.Markdown.RefsTest do
  use HelmsmanWeb.MarkdownCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  @moduletag slug: "acme"

  setup %{scope: scope} do
    project_fixture(scope, key: "BOS", name: "Bosun")
    for _ <- 1..12, do: task_fixture(scope, "BOS")

    beta_owner = user_fixture()
    beta = workspace_scope_fixture(beta_owner, workspace_fixture(beta_owner, %{slug: "beta"}))
    project_fixture(beta, key: "OPS", name: "Ops")
    task_fixture(beta, "OPS")
    :ok
  end

  defp links(html) do
    links = html |> parse() |> LazyHTML.query("a.hm-ref")
    Enum.zip(LazyHTML.attribute(links, "href"), Enum.map(links, &LazyHTML.text/1))
  end

  describe "the spec scenarios" do
    test "existing tasks and feedback entries", %{scope: scope} do
      assert links(render("参见 #bos-12 和 BOS-12#3", scope)) == [
               {"/w/acme/t/BOS-12", "BOS-12"},
               {"/w/acme/t/BOS-12#feedback-3", "BOS-12#3"}
             ]
    end

    test "a task that does not exist stays text", %{scope: scope} do
      html = render("#BOS-999 与 BOS-999#1", scope)
      assert count(html, "a") == 0
      assert html =~ "#BOS-999 与 BOS-999#1"
    end

    test "references in code are not linked", %{scope: scope} do
      html = render("`#BOS-12`\n\n```\n#BOS-12 BOS-12#3\n```\n", scope)
      assert count(html, "a") == 0
    end

    test "tasks of other workspaces stay text", %{scope: scope} do
      html = render("#OPS-1", scope)
      assert count(html, "a") == 0
      assert html =~ "#OPS-1"
    end
  end

  test "references in link text are not linked", %{scope: scope} do
    html = render("[#BOS-12](https://x.example) <https://x.example/#BOS-12>", scope)
    assert links(html) == []
    assert count(html, "a") == 2
  end

  test "references must stand alone", %{scope: scope} do
    for text <- [
          "x#BOS-12",
          "#BOS-12a",
          "#BOS-12-1",
          "##BOS-12",
          "/#BOS-12",
          "BOS-12#3a",
          "#BOS-12#3",
          "BOS-012",
          "#BOS-012"
        ] do
      assert links(render(text, scope)) == [], text
    end

    assert links(render("(#BOS-12), BOS-1#2.", scope)) == [
             {"/w/acme/t/BOS-12", "BOS-12"},
             {"/w/acme/t/BOS-1#feedback-2", "BOS-1#2"}
           ]
  end

  test "references in emphasis, lists, tables and footnotes are linked", %{scope: scope} do
    html =
      render(
        "**#BOS-1**\n\n- #BOS-2\n\n| a |\n|---|\n| #BOS-3 |\n\nx[^1]\n\n[^1]: #BOS-4\n",
        scope
      )

    assert Enum.map(links(html), &elem(&1, 1)) == ["BOS-1", "BOS-2", "BOS-3", "BOS-4"]
  end

  test "one query for every reference of a render", %{scope: scope} do
    text =
      Enum.map_join(1..30, " ", fn n -> if rem(n, 2) == 0, do: "#BOS-#{n}", else: "BOS-#{n}#1" end)

    assert {html, 1} = count_queries(fn -> render(text, scope) end)
    assert length(links(html)) == 12
    assert {_html, 0} = count_queries(fn -> render("no references", scope) end)
  end
end
