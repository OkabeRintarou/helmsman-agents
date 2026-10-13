defmodule HelmsmanWeb.API.RunsControllerTest do
  # add-rest-api 2.4, 3.1 and 8.1: runs. rest-api "运行与自动化端点".
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  alias Helmsman.{Agents, Repo, Runtimes}
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Runs.{Run, RunEvent}

  setup_all do
    %{spec: api_spec()}
  end

  setup do
    ctx = dispatch_fixture(%{access: "owner_only"})
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    token = token_for(ctx.alice, ctx.workspace)

    Map.merge(ctx, %{
      task: task,
      token: token,
      slug: ctx.workspace.slug,
      runtime_id: profile(ctx.agent).runtime_id,
      assign: trigger("assign", ctx.workspace, ctx.alice, ctx.agent)
    })
  end

  defp run_count, do: Repo.aggregate(Run, :count)

  defp failed(ctx, attrs \\ %{}) do
    run_fixture(
      ctx.agent,
      Map.merge(
        %{
          task_id: ctx.task.id,
          status: :failed,
          failure_reason: :provider_auth,
          triggers: [ctx.assign],
          finished_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp disable!(agent),
    do: agent |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()

  defp archive_profile(agent) do
    {1, _} =
      Repo.update_all(from(p in AgentProfile, where: p.actor_id == ^agent.id),
        set: [archived_at: DateTime.utc_now()]
      )

    {:ok, agent}
  end

  defp retry(ctx, run), do: api_send(:post, ctx.token, w(ctx.slug, "/runs/#{run.id}/retry"))

  describe "POST /runs" do
    test "starts the agent by hand: 201, queued", ctx do
      data =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/runs"), %{agent: "keel/dev", task_id: ctx.task.ident})
        |> body!(201)

      assert_schema(data["data"], "RunResult", ctx.spec)

      assert %{"run" => %{"status" => "QUEUED", "agent" => "keel/dev"}, "merged" => false} =
               data["data"]
    end

    test "someone who may not trigger the agent: 409 not_dispatched, no run", ctx do
      {_bob, token} = member_token(ctx.workspace, :member)
      count = run_count()

      detail =
        :post
        |> api_send(token, w(ctx.slug, "/runs"), %{agent: "keel/dev", task_id: ctx.task.ident})
        |> error!(409, "not_dispatched")

      assert detail == %{"reason" => "unauthorized"}
      assert run_count() == count
    end

    test "a squad is 422 is_squad", ctx do
      managed_agent_fixture(ctx.alice_scope, %{name: "keel/lead", access: "workspace"})
      Helmsman.SquadsFixtures.squad_fixture(ctx.alice_scope, %{name: "crew", leader: "keel/lead"})

      :post
      |> api_send(ctx.token, w(ctx.slug, "/runs"), %{agent: "crew", task_id: ctx.task.ident})
      |> error!(422, "is_squad")
    end
  end

  describe "POST /runs/:id/cancel" do
    test "stops a queued run; an ended one is 409 already_finished", ctx do
      run = run_fixture(ctx.agent, %{task_id: ctx.task.id, triggers: [ctx.assign]})

      data = :post |> api_send(ctx.token, w(ctx.slug, "/runs/#{run.id}/cancel")) |> body!(200)
      assert_schema(data["data"], "RunResult", ctx.spec)
      assert data["data"]["run"]["status"] == "CANCELLED"

      :post
      |> api_send(ctx.token, w(ctx.slug, "/runs/#{run.id}/cancel"))
      |> error!(409, "already_finished")
    end

    test "a run ID that is not a positive integer is 404", ctx do
      for id <- ["0", "-1", "abc", "999999999"] do
        :post
        |> api_send(ctx.token, w(ctx.slug, "/runs/#{id}/cancel"))
        |> error!(404, "not_found")
      end
    end
  end

  describe "GET /runs/:id and /runs/:id/events" do
    setup ctx do
      run = failed(ctx, %{error: "boom", events_seq: 5})
      at = DateTime.utc_now()

      for seq <- 1..5 do
        Repo.insert!(%RunEvent{
          run_id: run.id,
          seq: seq,
          type: "text",
          data: %{"text" => "e#{seq}"},
          at: at
        })
      end

      %{run: run}
    end

    test "a viewer sees the run but not its events", ctx do
      {_viewer, token} = member_token(ctx.workspace, :viewer)

      data = token |> api_get(w(ctx.slug, "/runs/#{ctx.run.id}")) |> body!(200)
      assert_schema(data["data"], "Run", ctx.spec)
      refute Map.has_key?(data["data"], "error")

      token |> api_get(w(ctx.slug, "/runs/#{ctx.run.id}/events")) |> error!(403, "forbidden")
    end

    test "a member sees the error text and the events", ctx do
      data = ctx.token |> api_get(w(ctx.slug, "/runs/#{ctx.run.id}")) |> body!(200)
      assert_schema(data["data"], "Run", ctx.spec)
      assert %{"status" => "FAILED", "error" => "boom"} = data["data"]

      data = ctx.token |> api_get(w(ctx.slug, "/runs/#{ctx.run.id}/events")) |> body!(200)
      assert_schema(data["data"], "RunEvents", ctx.spec)
      assert %{"pruned" => false, "last_seq" => 5, "events" => events} = data["data"]
      assert [%{"seq" => 1, "kind" => "text", "data" => %{"text" => "e1"}} | _] = events
      assert length(events) == 5
    end

    test "pages: after_seq, before_seq, latest, limit", ctx do
      seqs = fn query ->
        ctx.token
        |> api_get(w(ctx.slug, "/runs/#{ctx.run.id}/events?#{query}"))
        |> body!(200)
        |> get_in(["data", "events"])
        |> Enum.map(& &1["seq"])
      end

      assert seqs.("after_seq=2&limit=2") == [3, 4]
      assert seqs.("before_seq=4&limit=2") == [2, 3]
      assert seqs.("latest=true&limit=2") == [4, 5]

      ctx.token
      |> api_get(w(ctx.slug, "/runs/#{ctx.run.id}/events?limit=many"))
      |> error!(400, "invalid_params")
    end

    test "a pruned run has no events left", ctx do
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: [events_pruned_at: DateTime.utc_now()]
      )

      data = ctx.token |> api_get(w(ctx.slug, "/runs/#{ctx.run.id}/events")) |> body!(200)
      assert data["data"] == %{"events" => [], "pruned" => true, "last_seq" => 5}
    end

    test "an unknown run is 404", ctx do
      ctx.token |> api_get(w(ctx.slug, "/runs/999999999")) |> error!(404, "not_found")
      ctx.token |> api_get(w(ctx.slug, "/runs/x/events")) |> error!(404, "not_found")
    end
  end

  describe "POST /runs/:id/retry" do
    test "queues a retry: 200; again, the same queued retry", ctx do
      run = failed(ctx)

      data = ctx |> retry(run) |> body!(200)
      assert_schema(data["data"], "RunResult", ctx.spec)
      assert %{"run" => %{"id" => id, "status" => "QUEUED"}} = data["data"]
      assert id != run.id

      assert %{"data" => %{"run" => %{"id" => ^id}}} = ctx |> retry(run) |> body!(200)

      Repo.update_all(from(r in Run, where: r.id == ^id), set: [status: :failed])
      assert ctx |> retry(run) |> error!(409, "already_retried") == %{"run_id" => id}
    end

    test "a running or succeeded run is 409 not_ended, without a new run", ctx do
      for status <- [:running, :succeeded] do
        run =
          run_fixture(ctx.agent, %{task_id: ctx.task.id, status: status, triggers: [ctx.assign]})

        count = run_count()
        ctx |> retry(run) |> error!(409, "not_ended")
        assert run_count() == count
      end
    end

    test "a design run is 409 not_retryable", ctx do
      design = %{
        "kind" => "design",
        "design_id" => 1,
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      run = failed(ctx, %{task_id: nil, triggers: [design]})
      count = run_count()
      ctx |> retry(run) |> error!(409, "not_retryable")
      assert run_count() == count
    end

    test "a target that cannot run is 409 with its reason, without a new run", ctx do
      cases = [
        {"runtime_disabled", fn -> Runtimes.disable(ctx.alice_scope, ctx.runtime_id) end},
        {"no_runtime", fn -> Agents.update(ctx.alice_scope, "keel/dev", %{runtime_id: nil}) end},
        # Archiving also disables: only the profile's mark, to see the reason.
        {"agent_archived", fn -> archive_profile(ctx.agent) end},
        {"agent_disabled", fn -> {:ok, disable!(ctx.agent)} end}
      ]

      # The runs exist first; each change adds to the previous ones, in the
      # order of the checks (agent before runtime).
      runs = Enum.map(cases, fn _case -> failed(ctx) end)

      for {{code, change}, run} <- Enum.zip(cases, runs) do
        {:ok, _} = change.()
        count = run_count()
        ctx |> retry(run) |> error!(409, code)
        assert run_count() == count
      end
    end

    test "a work run of a verified task is 409 task_closed", ctx do
      Helmsman.LinksFixtures.set_status!(ctx.task, :verified)
      run = failed(ctx)
      count = run_count()
      ctx |> retry(run) |> error!(409, "task_closed")
      assert run_count() == count
    end

    test "an actor that is not a string is 400 on actor, without a retry", ctx do
      run = failed(ctx)
      count = run_count()

      for actor <- [17, true, %{"name" => "keel/dev"}, ["keel/dev"]] do
        detail =
          :post
          |> api_send(ctx.token, w(ctx.slug, "/runs/#{run.id}/retry"), %{actor: actor})
          |> error!(400, "invalid_params")

        assert Map.keys(detail["fields"]) == ["actor"]
      end

      assert run_count() == count
      assert Repo.get!(Run, run.id).status == :failed
    end

    test "the actor in the body or header: own agent, someone else's, conflict", ctx do
      keel = Helmsman.ApiTokensFixtures.agent_fixture(ctx.workspace, ctx.alice, "keel/own")
      bob = Helmsman.AccountsFixtures.user_fixture()
      Helmsman.WorkspacesFixtures.member_fixture(ctx.workspace, bob, :member)
      Helmsman.ApiTokensFixtures.agent_fixture(ctx.workspace, bob, "bob/dev")
      run = failed(ctx)
      path = w(ctx.slug, "/runs/#{run.id}/retry")

      :post |> api_send(ctx.token, path, %{actor: "bob/dev"}) |> error!(403, "forbidden")

      :post
      |> api_send(ctx.token, path, %{actor: "keel/own"}, [{"x-helmsman-actor", "keel/dev"}])
      |> error!(400, "invalid_params")

      data = :post |> api_send(ctx.token, path, %{actor: "keel/own"}) |> body!(200)
      assert %{"run" => %{"triggers" => triggers}} = data["data"]
      assert %{"by" => %{"name" => "keel/own"}} = List.last(triggers)
      _ = keel
    end

    test "someone else's run is 403 for a member", ctx do
      run = failed(ctx)
      {_carol, token} = member_token(ctx.workspace, :member)
      :post |> api_send(token, w(ctx.slug, "/runs/#{run.id}/retry")) |> error!(403, "forbidden")
    end
  end
end
