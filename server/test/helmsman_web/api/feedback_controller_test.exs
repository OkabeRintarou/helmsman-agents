defmodule HelmsmanWeb.API.FeedbackControllerTest do
  # add-rest-api 2.2 and 3.1: feedback.
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  alias Helmsman.Feedback

  setup_all do
    %{spec: api_spec()}
  end

  setup do
    ctx = api_fixture()
    project_fixture(ctx.scope, %{key: "BOS"})
    task_fixture(ctx.scope, "BOS")
    agent_fixture(ctx.workspace, ctx.alice, "keel/dev")
    ctx
  end

  defp add!(ctx, content, headers \\ []) do
    :post
    |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1/feedback"), %{content: content}, headers)
    |> body!(201)
  end

  test "POST adds a feedback by the human identity by default: 201", ctx do
    data = add!(ctx, "Looks good")
    assert_schema(data["data"], "Feedback", ctx.spec)
    human = Helmsman.Actors.get_human(ctx.workspace.id, ctx.alice.id)
    assert %{"id" => "BOS-1#1", "author" => %{"name" => name, "kind" => "human"}} = data["data"]
    assert name == human.name
  end

  test "author in the body writes as that agent", ctx do
    data =
      :post
      |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1/feedback"), %{
        content: "From the agent",
        author: "keel/dev"
      })
      |> body!(201)

    assert data["data"]["author"] == %{"name" => "keel/dev", "kind" => "agent"}
  end

  test "GET lists the feedback; GET /:seq one record", ctx do
    add!(ctx, "first")
    add!(ctx, "second")

    data = ctx.token |> api_get(w(ctx.slug, "/tasks/BOS-1/feedback")) |> body!(200)
    assert_schema(data["data"], "FeedbackList", ctx.spec)
    assert %{"task_id" => "BOS-1", "feedback" => [_, _]} = data["data"]

    data = ctx.token |> api_get(w(ctx.slug, "/tasks/BOS-1/feedback/2")) |> body!(200)
    assert_schema(data["data"], "Feedback", ctx.spec)
    assert %{"id" => "BOS-1#2", "content" => "second"} = data["data"]

    for seq <- ["9", "0", "x"] do
      ctx.token
      |> api_get(w(ctx.slug, "/tasks/BOS-1/feedback/#{seq}"))
      |> error!(404, "not_found")
    end
  end

  test "the single record is what MCP shows of it", ctx do
    add!(ctx, "first")
    {:ok, entry} = Feedback.get(ctx.scope, "BOS-1#1")

    expected =
      entry
      |> Feedback.view()
      |> HelmsmanMCP.Present.feedback()
      |> Jason.encode!()
      |> Jason.decode!()

    assert ctx.token |> api_get(w(ctx.slug, "/tasks/BOS-1/feedback/1")) |> body!(200) ==
             %{"data" => expected}
  end

  test "PATCH /:seq revises the record: a new one supersedes it", ctx do
    add!(ctx, "one")
    add!(ctx, "two")
    add!(ctx, "three")

    data =
      :patch
      |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1/feedback/3"), %{content: "updated"})
      |> body!(200)

    assert_schema(data["data"], "Feedback", ctx.spec)
    assert %{"id" => "BOS-1#4", "content" => "updated", "supersedes" => "BOS-1#3"} = data["data"]

    detail =
      :patch
      |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1/feedback/3"), %{content: "again"})
      |> error!(409, "superseded")

    assert detail == %{"latest" => "BOS-1#4"}
  end

  test "a viewer reads feedback but cannot add any", ctx do
    add!(ctx, "first")
    {_viewer, token} = member_token(ctx.workspace, :viewer)

    assert token |> api_get(w(ctx.slug, "/tasks/BOS-1/feedback/1")) |> body!(200)

    :post
    |> api_send(token, w(ctx.slug, "/tasks/BOS-1/feedback"), %{content: "no"})
    |> error!(403, "forbidden")
  end
end
