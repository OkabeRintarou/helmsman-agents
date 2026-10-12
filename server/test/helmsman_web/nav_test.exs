defmodule HelmsmanWeb.NavTest do
  use ExUnit.Case, async: true

  alias HelmsmanWeb.Nav

  @scope %{workspace: %{slug: "acme"}, role: :member}

  defp items do
    [
      %{
        id: :mine,
        group: :my_work,
        label: "我的任务",
        icon: "lucide-user",
        path: &"/w/#{&1.workspace.slug}"
      },
      %{
        id: :projects,
        group: :projects,
        label: fn -> "查看全部" end,
        icon: "lucide-folder",
        path: &"/w/#{&1.workspace.slug}/projects",
        badge: fn _ -> 3 end
      },
      %{
        id: :settings,
        group: :config,
        label: "设置",
        icon: "lucide-settings",
        path: &"/w/#{&1.workspace.slug}/settings",
        visible?: &(&1.role == :admin)
      }
    ]
  end

  test "groups come in order and the current item is marked" do
    groups = Nav.items_for(@scope, "/w/acme/projects/bos", items())

    assert Enum.map(groups, & &1.id) == [:my_work, :projects]
    assert [%{label: "我的工作"}, %{label: "项目", items: [projects]}] = groups
    assert projects.current?
    assert projects.badge == 3
    assert projects.label == "查看全部"

    [%{items: [mine]} | _] = groups
    refute mine.current?
  end

  test "the longest matching path wins and unrelated paths mark nothing" do
    [%{items: [mine]}, %{items: [projects]}] = Nav.items_for(@scope, "/w/acme", items())
    assert mine.current?
    refute projects.current?

    groups = Nav.items_for(@scope, "/w/acmex", items())
    refute Enum.any?(groups, fn g -> Enum.any?(g.items, & &1.current?) end)
  end

  test "items whose visibility function returns false are hidden, and so are empty groups" do
    groups = Nav.items_for(@scope, "/w/acme", items())
    refute Enum.any?(groups, &(&1.id == :config))

    admin = Nav.items_for(%{@scope | role: :admin}, "/w/acme/settings", items())
    assert %{id: :config, items: [%{current?: true}]} = List.last(admin)
  end

  test "查看全部 is registered in the 项目 group" do
    assert [%{id: :projects, items: [all]}] = Nav.items_for(@scope, "/w/acme/projects")
    assert all.id == :projects
    assert all.label == "查看全部"
    assert all.path == "/w/acme/projects"
    assert all.current?
  end

  describe "project items" do
    @projects [%{key: "BOS", name: "Bosun"}, %{key: "BOSX", name: "Bosun X"}]

    defp project_groups(path),
      do: Nav.items_for(@scope, path, Nav.project_items(@projects) ++ Nav.items())

    defp current(groups),
      do: for(g <- groups, i <- g.items, i.current?, do: i.id)

    test "projects come before 查看全部 and carry their key as hint" do
      assert [%{id: :projects, items: items}] = project_groups("/w/acme")
      assert Enum.map(items, & &1.id) == [{:project, "BOS"}, {:project, "BOSX"}, :projects]
      assert [%{label: "Bosun", hint: "BOS", path: "/w/acme/p/BOS"} | _] = items
    end

    test "a project is current on its list and on its tasks' pages" do
      assert current(project_groups("/w/acme/p/BOS")) == [{:project, "BOS"}]
      assert current(project_groups("/w/acme/t/BOS-3")) == [{:project, "BOS"}]
      assert current(project_groups("/w/acme/t/BOSX-1")) == [{:project, "BOSX"}]
      assert current(project_groups("/w/acme/projects")) == [:projects]
      assert current(project_groups("/w/acme/t/API-1")) == []
    end
  end
end
