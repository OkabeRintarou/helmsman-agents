defmodule Helmsman.GitHub.Webhooks.PullRequestsTest do
  # add-pr-reconcile-merge 1.9: pull request and check events only wake
  # the reconciliation (decision 13; pull-requests "GitHub 事件唤醒对账").
  use HelmsmanWeb.ConnCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Ecto.Query

  import Helmsman.GitHubFixtures
  import Helmsman.PullRequestFixtures

  alias Helmsman.FakeGitHub
  alias Helmsman.GitHub.Webhooks.PullRequests, as: Hook
  alias Helmsman.GitHub.Workers.{HandleWebhook, ReconcilePR}
  alias Helmsman.Repo

  setup do
    ctx = pr_fixture()

    Repo.update_all(where(Helmsman.GitHub.Repository, id: ^ctx.repository.id),
      set: [github_id: 777_001]
    )

    pr = pr_row(ctx, %{number: 12, head_sha: sha("c")})
    Repo.delete_all(Oban.Job)
    Map.merge(ctx, %{pr: pr})
  end

  defp repo, do: %{"id" => 777_001, "full_name" => "acme/app"}

  defp jobs(task_id), do: all_enqueued(worker: ReconcilePR, args: %{task_id: task_id})

  defp pull_request(number, ref, action \\ "synchronize") do
    %{
      "action" => action,
      "repository" => repo(),
      "pull_request" => %{"number" => number, "head" => %{"ref" => ref, "sha" => sha("c")}}
    }
  end

  test "check_suite completed for the current head (检查完成)", ctx do
    payload = %{
      "action" => "completed",
      "repository" => repo(),
      "check_suite" => %{"head_sha" => sha("c"), "pull_requests" => []}
    }

    assert :ok = Hook.handle("check_suite", payload)
    assert [_job] = jobs(ctx.task.id)
  end

  test "check_run by its pull request numbers; status by commit", ctx do
    payload = %{
      "repository" => repo(),
      "check_run" => %{"head_sha" => sha("9"), "pull_requests" => [%{"number" => 12}]}
    }

    assert :ok = Hook.handle("check_run", payload)
    assert [_] = jobs(ctx.task.id)

    Repo.delete_all(Oban.Job)

    assert :ok =
             Hook.handle("status", %{
               "repository" => repo(),
               "sha" => sha("c"),
               "state" => "success"
             })

    assert [_] = jobs(ctx.task.id)

    # Only draft and open pull requests are looked up by commit.
    Repo.delete_all(Oban.Job)
    Repo.update_all(where(Helmsman.GitHub.PullRequest, id: ^ctx.pr.id), set: [state: :merged])
    assert :ok = Hook.handle("status", %{"repository" => repo(), "sha" => sha("c")})
    assert jobs(ctx.task.id) == []
  end

  test "pull_request by number, or by the branch of the repository's workspace", ctx do
    assert :ok = Hook.handle("pull_request", pull_request(12, "whatever"))
    assert [_] = jobs(ctx.task.id)

    Repo.delete_all(Oban.Job)
    Repo.delete_all(Helmsman.GitHub.PullRequest)
    assert :ok = Hook.handle("pull_request", pull_request(99, ctx.branch, "opened"))
    assert [_] = jobs(ctx.task.id)
  end

  test "a branch name of another workspace wakes nothing (别的工作区的分支名)", ctx do
    Repo.delete_all(Helmsman.GitHub.PullRequest)
    other = "hm/#{ctx.workspace.id + 1}/" <> String.downcase(ctx.task.ident)

    assert :ok = Hook.handle("pull_request", pull_request(99, other, "opened"))
    assert all_enqueued(worker: ReconcilePR) == []
  end

  test "unknown repositories, tasks and the repository the project left are ignored", ctx do
    assert :ok =
             Hook.handle("pull_request", %{pull_request(12, "x") | "repository" => %{"id" => 1}})

    assert :ok = Hook.handle("pull_request", pull_request(13, "hm/#{ctx.workspace.id}/nope-1"))
    assert :ok = Hook.handle("status", %{"repository" => repo(), "sha" => sha("d")})
    assert :ok = Hook.handle("pull_request", %{"repository" => repo()})
    assert all_enqueued(worker: ReconcilePR) == []

    other = repository_fixture(ctx.installation, %{owner: "acme", name: "other"})
    bind_repository(ctx.project, other)
    assert :ok = Hook.handle("pull_request", pull_request(12, ctx.branch))

    assert :ok =
             Hook.handle("check_suite", %{
               "repository" => repo(),
               "check_suite" => %{"head_sha" => sha("c")}
             })

    assert all_enqueued(worker: ReconcilePR) == []
  end

  test "duplicated and out-of-order events: one wake-up, the facts read from GitHub (乱序与重复的事件)",
       ctx do
    fake = FakeGitHub.start()
    FakeGitHub.put_pull(fake, 12, %{head_ref: ctx.branch, head_sha: sha("c"), draft: true})
    Repo.update_all(where(Helmsman.GitHub.PullRequest, id: ^ctx.pr.id), set: [state: :draft])
    pushed_run(ctx, sha("c"), sha("0"))
    {:ok, _} = move(ctx.alice_scope, ctx.task, [:in_progress, :done])
    Repo.delete_all(Oban.Job)

    suite = %{"repository" => repo(), "check_suite" => %{"head_sha" => sha("c")}}
    assert :ok = Hook.handle("check_suite", suite)
    assert :ok = Hook.handle("pull_request", pull_request(12, ctx.branch, "closed"))
    assert :ok = Hook.handle("pull_request", pull_request(12, ctx.branch, "closed"))
    assert [_job] = jobs(ctx.task.id)

    # The payloads said "closed": GitHub says draft, the task is done.
    assert :ok = perform_job(ReconcilePR, %{task_id: ctx.task.id})
    assert :ok = perform_job(ReconcilePR, %{task_id: ctx.task.id})
    assert Enum.count(FakeGitHub.requests(fake), &(&1.path == "/graphql")) == 1
    assert %{state: :open} = Repo.get!(Helmsman.GitHub.PullRequest, ctx.pr.id)
  end

  test "a signed delivery through POST /webhooks/github", %{conn: conn} = ctx do
    payload =
      "test/fixtures/github/pull_request_opened.json"
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["installation", "id"], ctx.installation.installation_id)
      |> put_in(["repository", "id"], 777_001)
      |> put_in(["pull_request", "number"], 12)

    body = Jason.encode!(payload)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-delivery", "pr-#{System.unique_integer([:positive])}")
      |> put_req_header("x-github-event", "pull_request")
      |> put_req_header("x-hub-signature-256", sign(body))
      |> post("/webhooks/github", body)

    assert conn.status == 202
    assert [job] = all_enqueued(worker: HandleWebhook)
    assert :ok = perform_job(HandleWebhook, job.args)
    assert [_] = jobs(ctx.task.id)
  end
end
