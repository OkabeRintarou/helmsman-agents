defmodule HelmsmanWeb.API.TasksControllerTest do
  # add-rest-api 2.2: tasks. rest-api "资源与 MCP 工具一致", "请求参数",
  # "错误体与状态码" and "写入与读取身份".
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.LinksFixtures, only: [set_status!: 2]
  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  alias Helmsman.Actors.Actor
  alias Helmsman.{Links, Repo, Tasks}
  alias Helmsman.Tasks.Task

  setup_all do
    %{spec: api_spec()}
  end

  setup do
    ctx = api_fixture()
    project_fixture(ctx.scope, %{key: "BOS"})
    project_fixture(ctx.scope, %{key: "OTHER"})
    tasks = for _ <- 1..3, do: task_fixture(ctx.scope, "BOS")
    keel = agent_fixture(ctx.workspace, ctx.alice, "keel/dev")
    Map.merge(ctx, %{tasks: tasks, keel: keel})
  end

  defp task!(ident), do: Repo.get_by!(Task, ident: ident)
  defp task_count, do: Repo.aggregate(Task, :count)

  describe "GET /projects/:key/tasks" do
    test "status list and limit", ctx do
      [one, two, _three] = ctx.tasks
      set_status!(one, :in_progress)
      set_status!(two, :done)

      data =
        ctx.token
        |> api_get(w(ctx.slug, "/projects/BOS/tasks?status=NEW,IN_PROGRESS&limit=10"))
        |> body!(200)

      assert_schema(data["data"], "TaskList", ctx.spec)
      assert data["data"] |> Enum.map(& &1["status"]) |> Enum.sort() == ["IN_PROGRESS", "NEW"]

      data = ctx.token |> api_get(w(ctx.slug, "/projects/BOS/tasks?limit=1")) |> body!(200)
      assert length(data["data"]) == 1

      data =
        ctx.token
        |> api_get(w(ctx.slug, "/projects/BOS/tasks?status[]=DONE&status[]=NEW"))
        |> body!(200)

      assert data["data"] |> Enum.map(& &1["status"]) |> Enum.sort() == ["DONE", "NEW"]
    end

    test "a type error names the parameter", ctx do
      detail =
        ctx.token
        |> api_get(w(ctx.slug, "/projects/BOS/tasks?limit=ten"))
        |> error!(400, "invalid_params")

      assert Map.keys(detail["fields"]) == ["limit"]
    end

    test "an unknown status is 422 invalid_status", ctx do
      detail =
        ctx.token
        |> api_get(w(ctx.slug, "/projects/BOS/tasks?status=DONEE"))
        |> error!(422, "invalid_status")

      assert %{"value" => "DONEE", "valid" => ["NEW" | _]} = detail
    end
  end

  describe "POST /projects/:key/tasks" do
    test "creates a task with its dispatch: 201", ctx do
      managed_agent_fixture(ctx.scope, %{name: "keel/run", access: "workspace"})

      data =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/projects/BOS/tasks"), %{
          title: "Fix login",
          assignee: "keel/run"
        })
        |> body!(201)

      assert_schema(data["data"], "TaskDetail", ctx.spec)
      assert %{"id" => "BOS-4", "title" => "Fix login", "dispatch" => [dispatch]} = data["data"]
      assert %{"agent" => "keel/run", "result" => "queued"} = dispatch
    end

    test "the path parameter wins over the body's project_key", ctx do
      data =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/projects/BOS/tasks"), %{
          title: "Here",
          project_key: "OTHER"
        })
        |> body!(201)

      assert data["data"]["project_key"] == "BOS"
    end

    test "an empty title is 422 validation_failed with the field", ctx do
      count = task_count()

      detail =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/projects/BOS/tasks"), %{title: ""})
        |> error!(422, "validation_failed")

      assert %{"fields" => %{"title" => [_ | _]}} = detail
      assert task_count() == count
    end

    test "a missing title is 400 invalid_params", ctx do
      detail =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/projects/BOS/tasks"), %{})
        |> error!(400, "invalid_params")

      assert Map.keys(detail["fields"]) == ["title"]
    end

    test "an archived project is 409", ctx do
      {:ok, _} = Helmsman.Projects.archive(ctx.scope, "OTHER")

      :post
      |> api_send(ctx.token, w(ctx.slug, "/projects/OTHER/tasks"), %{title: "x"})
      |> error!(409, "project_archived")
    end
  end

  describe "GET /tasks/:id" do
    test "the detail", ctx do
      data = ctx.token |> api_get(w(ctx.slug, "/tasks/bos-1")) |> body!(200)
      assert_schema(data["data"], "TaskDetail", ctx.spec)
      assert data["data"]["id"] == "BOS-1"
    end

    test "an unknown task is 404", ctx do
      detail = ctx.token |> api_get(w(ctx.slug, "/tasks/BOS-999")) |> error!(404, "not_found")

      assert_schema(
        %{"error" => "not_found", "message" => "x", "detail" => detail},
        "Error",
        ctx.spec
      )
    end
  end

  describe "PATCH /tasks/:id" do
    test "changes the given fields only", ctx do
      data =
        :patch
        |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1"), %{title: "Renamed"})
        |> body!(200)

      assert_schema(data["data"], "TaskDetail", ctx.spec)
      assert %{"title" => "Renamed", "lock_version" => 2} = data["data"]
    end

    test "an old lock_version is 409 stale and changes nothing", ctx do
      {:ok, _} = Tasks.update(ctx.scope, "BOS-1", %{title: "Moved on"}, nil)
      before = task!("BOS-1")

      :patch
      |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1"), %{
        title: "x",
        lock_version: before.lock_version - 1
      })
      |> error!(409, "stale")

      assert %{title: "Moved on", lock_version: version} = task!("BOS-1")
      assert version == before.lock_version
    end
  end

  describe "POST /tasks/:id/transition" do
    test "moves the task; with X-Helmsman-Actor the history names the agent", ctx do
      data =
        :post
        |> api_send(
          ctx.token,
          w(ctx.slug, "/tasks/BOS-1/transition"),
          %{to: "IN_PROGRESS", feedback: %{content: "Starting"}},
          [{"x-helmsman-actor", "keel/dev"}]
        )
        |> body!(200)

      assert_schema(data["data"], "TaskDetail", ctx.spec)
      assert %{"status" => "IN_PROGRESS", "history" => history} = data["data"]
      assert %{"actor" => %{"name" => "keel/dev", "kind" => "agent"}} = List.last(history)
    end

    test "an invalid transition is 409 with from, to and the allowed targets", ctx do
      set_status!(hd(ctx.tasks), :done)

      detail =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1/transition"), %{to: "CANCELLED"})
        |> error!(409, "invalid_transition")

      assert %{"from" => "DONE", "to" => "CANCELLED", "allowed" => allowed} = detail
      assert "VERIFIED" in allowed
    end

    test "a task blocked by an unfinished one is 409 blocked", ctx do
      {:ok, _} = Links.add(ctx.scope, "BOS-2", "BOS-1", "depends_on")

      detail =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/transition"), %{to: "IN_PROGRESS"})
        |> error!(409, "blocked")

      assert detail == %{"blockers" => ["BOS-1"]}
    end
  end

  describe "identities (rest-api 写入与读取身份)" do
    setup ctx do
      bob = Helmsman.AccountsFixtures.user_fixture()
      Helmsman.WorkspacesFixtures.member_fixture(ctx.workspace, bob, :member)
      agent_fixture(ctx.workspace, bob, "bob/dev")
      bob_human = Helmsman.Actors.get_human(ctx.workspace.id, bob.id)
      %{bob_human: bob_human}
    end

    test "impersonation is 403 and writes nothing", ctx do
      for name <- ["bob/dev", ctx.bob_human.name] do
        :post
        |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1/transition"), %{to: "IN_PROGRESS"}, [
          {"x-helmsman-actor", name}
        ])
        |> error!(403, "forbidden")

        :post
        |> api_send(ctx.token, w(ctx.slug, "/projects/BOS/tasks"), %{title: "x", actor: name})
        |> error!(403, "forbidden")
      end

      assert task!("BOS-1").status == :new
      assert task_count() == 3
    end

    test "a disabled agent of one's own cannot write but can read", ctx do
      ctx.keel |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
      header = [{"x-helmsman-actor", "keel/dev"}]

      detail =
        :post
        |> api_send(
          ctx.token,
          w(ctx.slug, "/tasks/BOS-1/transition"),
          %{to: "IN_PROGRESS"},
          header
        )
        |> error!(403, "agent_disabled")

      assert detail == %{"actor" => "keel/dev"}
      assert ctx.token |> api_get(w(ctx.slug, "/tasks/BOS-1"), header) |> body!(200)
    end

    test "the header and the body naming different identities is 400", ctx do
      agent_fixture(ctx.workspace, ctx.alice, "keel/review")

      detail =
        :post
        |> api_send(
          ctx.token,
          w(ctx.slug, "/tasks/BOS-1/transition"),
          %{to: "IN_PROGRESS", actor: "keel/review"},
          [{"x-helmsman-actor", "keel/dev"}]
        )
        |> error!(400, "invalid_params")

      assert Map.keys(detail["fields"]) == ["actor"]
      assert task!("BOS-1").status == :new
    end

    test "with the token's default agent, writes are recorded as it", ctx do
      token = token_for(ctx.alice, ctx.workspace, %{default_agent_id: ctx.keel.id})

      data =
        :post
        |> api_send(token, w(ctx.slug, "/projects/BOS/tasks"), %{title: "By default"})
        |> body!(201)

      assert data["data"]["created_by"] == %{"name" => "keel/dev", "kind" => "agent"}
    end

    test "REST never creates a session agent", ctx do
      count = Repo.aggregate(from(a in Actor, where: like(a.name, "%/session-%")), :count)

      :post
      |> api_send(ctx.token, w(ctx.slug, "/projects/BOS/tasks"), %{title: "x"})
      |> body!(201)

      assert Repo.aggregate(from(a in Actor, where: like(a.name, "%/session-%")), :count) == count
    end
  end

  test "GET /tasks/:id/runs", ctx do
    data = ctx.token |> api_get(w(ctx.slug, "/tasks/BOS-1/runs")) |> body!(200)
    assert_schema(data["data"], "RunList", ctx.spec)
    assert data["data"] == %{"runs" => []}
  end
end
