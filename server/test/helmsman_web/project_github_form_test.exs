defmodule HelmsmanWeb.ProjectGitHubFormTest do
  @moduledoc "add-github-ui D6: the panel state submits only the changed settings."
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
      repository_id: project.repository_id,
      base_branch: project.base_branch || "",
      merge_policy: project.merge_policy,
      merge_method: project.merge_method,
      require_ci: project.require_ci,
      delete_branch_after_merge: project.delete_branch_after_merge
    }

    %{
      key: "BOS",
      base: values,
      params: values,
      current: nil,
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
end
