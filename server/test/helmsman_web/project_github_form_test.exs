defmodule HelmsmanWeb.ProjectGitHubFormTest do
  @moduledoc """
  add-github-ui D6: the panel state submits only the changed settings;
  add-local-repositories-ui D5: the local mode.
  """
  use ExUnit.Case, async: true

  alias Helmsman.Projects.Project
  alias HelmsmanWeb.ProjectGitHubForm

  defp form(attrs \\ %{}) do
    project =
      struct!(
        Project,
        Map.merge(
          %{key: "BOS", repository_id: 1, base_branch: "develop", repository: nil},
          attrs
        )
      )

    values = %{
      local_repository_id: project.local_repository_id,
      repository_id: project.repository_id,
      base_branch: project.base_branch || "",
      merge_policy: project.merge_policy,
      merge_method: project.merge_method,
      require_ci: project.require_ci,
      delete_branch_after_merge: project.delete_branch_after_merge
    }

    %{
      key: "BOS",
      mode: if(project.local_repository_id, do: :local, else: :github),
      base: values,
      params: values,
      current: nil,
      current_local: nil,
      locals: [],
      repositories: [
        %{id: 1, full_name: "acme/web", private: false, available: true, default_branch: "main"},
        %{id: 2, full_name: "acme/api", private: true, available: true, default_branch: "trunk"},
        %{id: 3, full_name: "acme/old", private: false, available: false, default_branch: "main"}
      ],
      branches: ["main"],
      errors: %{},
      alert: nil,
      saving?: false
    }
  end

  @unchanged %{
    "repository_id" => "1",
    "base_branch" => "develop",
    "merge_policy" => "on_verified",
    "merge_method" => "squash",
    "require_ci" => "true",
    "delete_branch_after_merge" => "true"
  }

  test "an unchanged form submits nothing" do
    form = ProjectGitHubForm.change(form(), @unchanged)
    assert ProjectGitHubForm.attrs(form) == %{}
    refute ProjectGitHubForm.dirty?(form)
  end

  test "only the changed keys are submitted" do
    form =
      ProjectGitHubForm.change(
        form(),
        Map.merge(@unchanged, %{"merge_policy" => "manual", "require_ci" => "false"})
      )

    assert ProjectGitHubForm.attrs(form) == %{merge_policy: "manual", require_ci: false}
  end

  test "another repository clears the base branch and the suggestions" do
    form = ProjectGitHubForm.change(form(), Map.put(@unchanged, "repository_id", "2"))

    assert form.params.base_branch == ""
    assert form.branches == []
    assert ProjectGitHubForm.attrs(form) == %{repository_id: 2, base_branch: nil}

    form = ProjectGitHubForm.select_repository(form(), nil)
    assert ProjectGitHubForm.attrs(form) == %{repository_id: nil, base_branch: nil}
  end

  test "an emptied base branch means the default branch; whitespace is trimmed" do
    assert ProjectGitHubForm.attrs(
             ProjectGitHubForm.change(form(), %{@unchanged | "base_branch" => ""})
           ) == %{base_branch: nil}

    assert ProjectGitHubForm.attrs(
             ProjectGitHubForm.change(form(), %{@unchanged | "base_branch" => " main "})
           ) == %{base_branch: "main"}
  end

  test "fields missing from the params (disabled) and invalid values keep their value" do
    form =
      ProjectGitHubForm.change(form(), %{"merge_method" => "octopus", "require_ci" => "maybe"})

    assert ProjectGitHubForm.attrs(form) == %{}
  end

  test "options: available repositories plus the unavailable bound one" do
    assert form() |> ProjectGitHubForm.options() |> Enum.map(& &1.id) == [1, 2]

    assert form(%{repository_id: 3}) |> ProjectGitHubForm.options() |> Enum.map(& &1.id) == [
             3,
             1,
             2
           ]
  end

  test "errors map to fields, the panel alert or closing" do
    assert {:form, %{errors: %{base_branch: ["GitHub 上没有分支 x"]}}, false} =
             ProjectGitHubForm.errors(form(), {:branch_not_found, "x"})

    assert {:form, %{errors: %{repository_id: [_]}}, true} =
             ProjectGitHubForm.errors(form(), :repository_unavailable)

    assert {:form, %{alert: alert}, false} =
             ProjectGitHubForm.errors(form(), {:rate_limited, DateTime.utc_now()})

    assert alert =~ "暂时无法连接 GitHub"
    assert {:close, _message} = ProjectGitHubForm.errors(form(), :forbidden)
  end

  describe "local mode" do
    defp local(attrs \\ %{}),
      do: form(Map.merge(%{repository_id: nil, base_branch: nil, local_repository_id: 7}, attrs))

    test "an unbound project switches modes; each switch clears the other side" do
      form =
        form(%{repository_id: nil, base_branch: nil})
        |> ProjectGitHubForm.select_repository(2)
        |> ProjectGitHubForm.change(%{"repository_id" => "2", "base_branch" => "trunk"})

      form = ProjectGitHubForm.set_mode(form, :local)
      assert form.mode == :local
      assert form.params.repository_id == nil
      assert form.params.base_branch == ""
      refute ProjectGitHubForm.dirty?(form)

      form =
        form
        |> ProjectGitHubForm.select_local(9)
        |> ProjectGitHubForm.change(%{"local_repository_id" => "9", "base_branch" => "dev"})

      assert ProjectGitHubForm.local_attrs(form) == %{local_repository_id: 9, base_branch: "dev"}

      form = ProjectGitHubForm.set_mode(form, :github)
      assert form.mode == :github
      assert form.params.local_repository_id == nil
      assert form.params.base_branch == ""
      refute ProjectGitHubForm.dirty?(form)
    end

    test "a bound project cannot switch to the other mode" do
      assert ProjectGitHubForm.set_mode(form(), :local).mode == :github
      refute ProjectGitHubForm.can_switch?(form(), :local)
      assert ProjectGitHubForm.set_mode(local(), :github).mode == :local
      refute ProjectGitHubForm.can_switch?(local(), :github)
    end

    test "local_attrs/1 has only the changes" do
      form = local(%{base_branch: "main"})
      assert ProjectGitHubForm.local_attrs(form) == %{}
      refute ProjectGitHubForm.dirty?(form)

      form =
        ProjectGitHubForm.change(form, %{"local_repository_id" => "7", "base_branch" => " dev "})

      assert ProjectGitHubForm.local_attrs(form) == %{base_branch: "dev"}
      assert ProjectGitHubForm.local_binding(form) == {7, [base_branch: "dev"]}

      form =
        ProjectGitHubForm.change(local(%{base_branch: "main"}), %{"local_repository_id" => "8"})

      assert ProjectGitHubForm.local_attrs(form) == %{local_repository_id: 8, base_branch: ""}
      assert ProjectGitHubForm.local_binding(form) == {8, [base_branch: ""]}

      form = ProjectGitHubForm.change(local(), %{"local_repository_id" => "8"})
      assert ProjectGitHubForm.local_binding(form) == {8, []}
    end

    test "unbinding sends no base branch and ignores the branch input" do
      form = ProjectGitHubForm.select_local(local(%{base_branch: "main"}), nil)
      assert ProjectGitHubForm.local_binding(form) == {nil, []}
      assert ProjectGitHubForm.dirty?(form)

      form = ProjectGitHubForm.change(form, %{"local_repository_id" => "", "base_branch" => "x"})
      assert form.params.base_branch == ""
    end

    test "a removed repository is a field error that re-reads the options" do
      assert {:form, %{errors: %{local_repository_id: ["本地仓库已被移除"]}}, true} =
               ProjectGitHubForm.errors(local(), :not_found)
    end
  end
end
