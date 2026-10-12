defmodule Helmsman.Runs.PushColumnsTest do
  # add-daemon-git-workspace 1.1: the push columns of runs and their
  # constraints (decision 1), written directly to the database.
  use Helmsman.DataCase, async: true

  import Helmsman.GitRunFixtures

  alias Helmsman.Runs.Run

  setup do
    git_run_fixture()
  end

  defp write(run, sql_set, params) do
    Repo.query("UPDATE runs SET #{sql_set} WHERE id = $1", [run.id | params])
  end

  defp assert_check(result, constraint) do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation, constraint: ^constraint}}} =
             result
  end

  test "a new run has push_status none and no record", ctx do
    assert %Run{push_status: :none, pushed_at: nil, head_sha: nil, push_commits: nil} =
             Repo.get!(Run, ctx.run.id)

    {:ok, %{rows: [["none"]]}} =
      Repo.query("SELECT push_status FROM runs WHERE id = $1", [ctx.run.id])
  end

  test "pushed without head_sha is rejected", ctx do
    result =
      write(ctx.run, "push_status = 'pushed', base_sha = $2, pushed_at = now()", [sha("0")])

    assert_check(result, "runs_push_record_check")
  end

  test "conflict without a rescue branch is rejected", ctx do
    result =
      write(
        ctx.run,
        "push_status = 'conflict', base_sha = $2, head_sha = $3, pushed_at = now()",
        [sha("0"), sha("a")]
      )

    assert_check(result, "runs_rescue_branch_check")
  end

  test "an unknown push status is rejected", ctx do
    assert_check(write(ctx.run, "push_status = 'bogus'", []), "runs_push_status_check")
  end

  test "a record without push_status pushed or conflict is rejected", ctx do
    result =
      write(ctx.run, "base_sha = $2, head_sha = $3, pushed_at = now()", [sha("0"), sha("a")])

    assert_check(result, "runs_push_record_check")
    assert_check(write(ctx.run, "rescue_branch = 'x'", []), "runs_rescue_branch_check")
  end

  test "complete records are accepted; failed needs no record", ctx do
    assert {:ok, _} = write(ctx.run, "push_status = 'failed'", [])

    assert {:ok, _} =
             write(
               ctx.run,
               "push_status = 'conflict', base_sha = $2, head_sha = $3, pushed_at = now(), " <>
                 "rescue_branch = $4, push_commits = $5",
               [
                 sha("0"),
                 sha("a"),
                 "#{ctx.branch}-run-#{ctx.run.id}",
                 [%{sha: sha("a"), subject: "s"}]
               ]
             )

    assert %Run{push_status: :conflict, push_commits: [%{"sha" => _, "subject" => "s"}]} =
             Repo.get!(Run, ctx.run.id)
  end

  test "the repository must belong to the run's workspace", ctx do
    other = Helmsman.RunsFixtures.dispatch_fixture()
    installation = Helmsman.GitHubFixtures.installation_fixture(other.workspace)
    foreign = Helmsman.GitHubFixtures.repository_fixture(installation)

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             write(ctx.run, "repository_id = $2", [foreign.id])
  end
end
