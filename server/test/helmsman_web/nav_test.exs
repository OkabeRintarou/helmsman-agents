defmodule HelmsmanWeb.NavTest do
  use ExUnit.Case, async: true

  alias HelmsmanWeb.CommandPalette.Pages
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
    groups = Nav.items_for(@scope, "/w/acme/projects")
    assert %{items: [all]} = Enum.find(groups, &(&1.id == :projects))
    assert all.id == :projects
    assert all.label == "查看全部"
    assert all.path == "/w/acme/projects"
    assert all.current?
  end

  test "设置 is registered in the 配置 group and current on every settings page" do
    groups = Nav.items_for(@scope, "/w/acme/settings/tokens")
    assert %{label: "配置", items: [_runtimes, settings]} = Enum.find(groups, &(&1.id == :config))
    assert settings.id == :settings
    assert settings.label == "设置"
    assert settings.path == "/w/acme/settings"
    assert settings.current?
  end

  describe "project items" do
    @projects [%{key: "BOS", name: "Bosun"}, %{key: "BOSX", name: "Bosun X"}]

    defp project_groups(path),
      do: Nav.items_for(@scope, path, Nav.project_items(@projects) ++ Nav.items())

    defp current(groups),
      do: for(g <- groups, i <- g.items, i.current?, do: i.id)

    test "projects come before 查看全部 and carry their key as hint" do
      assert [%{id: :projects, items: items} | _] = project_groups("/w/acme")
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

  describe "运行时" do
    defp config_items(role, path) do
      groups = Nav.items_for(%{@scope | role: role}, path)
      Enum.find(groups, &(&1.id == :config)).items
    end

    test "a viewer does not see it" do
      assert [%{id: :settings}] = config_items(:viewer, "/w/acme")
    end

    test "members see it before 设置, current on its page instead of 设置" do
      assert [runtimes, settings] = config_items(:member, "/w/acme/settings/runtimes")
      assert runtimes.id == :runtimes
      assert runtimes.label == "运行时"
      assert runtimes.path == "/w/acme/settings/runtimes"
      assert runtimes.current?
      refute settings.current?

      assert [%{current?: false}, %{current?: true}] =
               config_items(:admin, "/w/acme/settings/members")
    end

    test "the command palette finds it once" do
      scope = %{@scope | role: :member}
      ctx = %{nav: Nav.items_for(scope, "/w/acme")}
      results = Pages.search(scope, "运行时", ctx)
      assert [%{label: "运行时", path: "/w/acme/settings/runtimes"}] = results
    end
  end

  test "Agents is in the Agent 团队 group for every role, current on detail pages" do
    for role <- [:viewer, :member, :admin] do
      groups = Nav.items_for(%{@scope | role: role}, "/w/acme/agents/keel/dev")
      assert %{label: "Agent 团队", items: [agents]} = Enum.find(groups, &(&1.id == :agents))
      assert agents.label == "Agents"
      assert agents.path == "/w/acme/agents"
      assert agents.current?
    end
  end

  describe "filter items (add-search-query-ui D8)" do
    defp filter(id, name, opts \\ []) do
      %{
        id: id,
        name: name,
        owner: Keyword.get(opts, :owner, %{display_name: "Alice"}),
        owner_left: Keyword.get(opts, :owner_left, false)
      }
    end

    defp filter_group(filters, current) do
      groups = Nav.items_for(@scope, current, Nav.filter_items(filters) ++ Nav.items())
      Enum.find(groups, &(&1.id == :filters))
    end

    defp current_ids(group), do: for(i <- group.items, i.current?, do: i.id)

    defp filters do
      %{
        mine: [filter(1, "我的新任务"), filter(2, "周报")],
        shared: [filter(3, "待合并"), filter(4, "旧的", owner: nil, owner_left: true)]
      }
    end

    test "查询, own filters and shared filters come in order with paths and hints" do
      group = filter_group(filters(), "/w/acme")

      assert group.label == "筛选器"

      assert Enum.map(group.items, & &1.id) == [
               :query,
               {:filter, "1"},
               {:filter, "2"},
               {:filter, "3"},
               {:filter, "4"}
             ]

      [query, mine | _] = group.items
      assert query.label == "查询"
      assert query.path == "/w/acme/query"
      assert mine.path == "/w/acme/query?filter=1"
      assert mine.hint == nil

      assert Enum.find(group.items, &(&1.id == {:filter, "3"})).hint == "Alice"
      assert Enum.find(group.items, &(&1.id == {:filter, "4"})).hint == "所有者已离开"
      assert current_ids(group) == []
    end

    test "the open filter is current, not 查询 (scenario 当前筛选器高亮)" do
      assert current_ids(filter_group(filters(), "/w/acme/query?filter=1")) == [{:filter, "1"}]

      assert current_ids(filter_group(filters(), "/w/acme/query?bql=x&filter=3")) == [
               {:filter, "3"}
             ]
    end

    test "查询 is current on the BQL page without a filter" do
      assert current_ids(filter_group(filters(), "/w/acme/query")) == [:query]
      assert current_ids(filter_group(filters(), "/w/acme/query?bql=status+%3D+new")) == [:query]
      assert current_ids(filter_group(%{mine: [], shared: []}, "/w/acme/query")) == [:query]
    end

    test "without filters only 查询 is listed" do
      assert [%{id: :query}] = filter_group(%{mine: [], shared: []}, "/w/acme").items
    end

    test "at most 15 own and 10 shared filters, then 全部筛选器 (scenario 超出上限)" do
      mine = for i <- 1..20, do: filter(i, "f#{String.pad_leading("#{i}", 2, "0")}")
      shared = for i <- 21..23, do: filter(i, "s#{i}")
      group = filter_group(%{mine: mine, shared: shared}, "/w/acme/query?panel=filters")

      ids = Enum.map(group.items, & &1.id)
      assert length(ids) == 1 + 15 + 3 + 1
      assert Enum.slice(ids, 1, 15) == for(i <- 1..15, do: {:filter, "#{i}"})
      assert List.last(group.items).id == :all_filters
      assert List.last(group.items).label == "全部筛选器"
      assert List.last(group.items).path == "/w/acme/query?panel=filters"
      assert current_ids(group) == [:all_filters]

      shared = for i <- 21..31, do: filter(i, "s#{i}")
      group = filter_group(%{mine: [], shared: shared}, "/w/acme")
      assert length(group.items) == 1 + 10 + 1

      group = filter_group(%{mine: Enum.take(mine, 15), shared: []}, "/w/acme")
      refute Enum.any?(group.items, &(&1.id == :all_filters))
    end

    test "other items still follow the path only" do
      groups =
        Nav.items_for(
          @scope,
          "/w/acme/projects?status=new",
          Nav.filter_items(filters()) ++ Nav.items()
        )

      assert for(g <- groups, i <- g.items, i.current?, do: i.id) == [:projects]
    end
  end
end
