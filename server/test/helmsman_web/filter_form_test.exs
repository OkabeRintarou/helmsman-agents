defmodule HelmsmanWeb.FilterFormTest do
  @moduledoc "The save / edit filter panel (add-search-query-ui D6)."
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Helmsman.Filters.SavedFilter
  alias HelmsmanWeb.FilterForm

  @filter %{id: 1, name: "待合并", bql: "pr = open", visibility: :workspace}

  defp panel(form),
    do: render_component(&FilterForm.panel/1, form: form, close_path: "/w/acme/query")

  test "a new form is private and empty; the owner may choose the visibility" do
    form = FilterForm.new(:create)
    assert form.params == %{"name" => "", "visibility" => "private"}
    refute FilterForm.dirty?(form)

    form = FilterForm.change(form, %{"name" => " 我的新任务 ", "visibility" => "workspace"})
    assert FilterForm.dirty?(form)
    assert FilterForm.attrs(form) == %{name: "我的新任务", visibility: :workspace}

    html = panel(form)
    assert html =~ "另存为筛选器"
    assert html =~ "仅自己"
    assert html =~ "工作区共享"
    assert html =~ "共享后工作区所有成员可见、可运行；所有者与管理员可以修改。"
    assert html =~ ~s(value="workspace" checked)
  end

  test "an edit form without the visibility right keeps it read-only and out of the attrs" do
    form = FilterForm.new(:edit, @filter, false)
    assert form.params == %{"name" => "待合并", "visibility" => "workspace"}

    form = FilterForm.change(form, %{"name" => "新名字", "visibility" => "private"})
    assert form.params["visibility"] == "workspace"
    assert FilterForm.attrs(form) == %{name: "新名字"}

    html = panel(form)
    assert html =~ "编辑筛选器"
    assert html =~ "只有所有者能改变可见性"
    refute html =~ ~s(type="radio")
  end

  test "the owner's edit form changes the visibility" do
    form =
      @filter
      |> then(&FilterForm.new(:edit, &1, true))
      |> FilterForm.change(%{"name" => "x", "visibility" => "private"})

    assert FilterForm.attrs(form) == %{name: "x", visibility: :private}

    assert FilterForm.change(form, %{"name" => "x", "visibility" => "evil"}).params["visibility"] ==
             "private"
  end

  test "name errors go to the field, a BQL error with its position to the top" do
    changeset = SavedFilter.changeset(%SavedFilter{}, %{name: String.duplicate("x", 81), bql: ""})
    form = FilterForm.put_error(FilterForm.new(:create), changeset)
    assert form.errors == %{name: ["长度须为 1–80 个字符"]}
    assert form.error == nil

    changeset = SavedFilter.changeset(%SavedFilter{}, %{name: "x", bql: "foo = 1"})
    assert [bql: {"unknown field 'foo' (position 1)", _}] = changeset.errors

    form = FilterForm.put_error(FilterForm.new(:create), changeset)
    assert form.errors == %{}
    assert form.error == {:bql, %{message: "unknown field 'foo'", position: 1}}

    html = panel(form)
    assert html =~ "查询无效：第 1 个字符：unknown field &#39;foo&#39;"
    refute html =~ "(position 1)"
  end

  test "a duplicate name and the per-user limit are explained" do
    changeset =
      %SavedFilter{}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:name, "has already been taken")

    assert FilterForm.put_error(FilterForm.new(:create), changeset).errors ==
             %{name: ["你已有同名的筛选器"]}

    changeset =
      %SavedFilter{}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:name, "at most 100 filters per workspace")

    assert FilterForm.put_error(FilterForm.new(:create), changeset).errors ==
             %{name: ["筛选器数量已达上限，请先删除不用的筛选器"]}
  end

  test "a stale save offers 载入最新; other failures are one sentence" do
    html = FilterForm.new(:edit, @filter, true) |> FilterForm.put_error(:stale) |> panel()
    assert html =~ "这个筛选器刚被修改"
    assert html =~ ~s(id="filter-form-load-latest")
    assert html =~ "load_latest"

    form = FilterForm.put_error(FilterForm.new(:create), :limit_reached)
    assert form.error == {:message, "筛选器数量已达上限，请先删除不用的筛选器"}
    assert FilterForm.put_error(form, :forbidden).error == {:message, "没有权限执行此操作"}
  end

  test "a closed panel renders no form" do
    refute panel(nil) =~ ~s(id="filter-form")
  end
end
