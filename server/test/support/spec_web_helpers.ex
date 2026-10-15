defmodule HelmsmanWeb.SpecWebHelpers do
  @moduledoc """
  Helpers of the spec page tests (add-spec-workflow-ui D18) on top of
  `Helmsman.TaskSpecsFixtures.specs_fixture/1`: alice (owner), bob and carol (members),
  `web-team` (leader `keel/lead`) assigned to the task, and a viewer `vic`. Writes made by
  agents (versions, reviews, proposals) go through their run scopes.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Helmsman.TaskSpecsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.TaskSpecs

  @doc "The specs workspace with `ident`, `path` (the spec page) and `vic` (a viewer)."
  def spec_web_fixture(opts \\ %{}) do
    ctx = specs_fixture(opts)
    {vic, vic_scope} = member_scope_fixture(ctx.workspace, :viewer)
    ident = ctx.task.ident
    slug = ctx.workspace.slug

    Map.merge(ctx, %{
      ident: ident,
      slug: slug,
      vic: vic,
      vic_scope: vic_scope,
      path: "/w/#{slug}/t/#{ident}/spec",
      task_path: "/w/#{slug}/t/#{ident}"
    })
  end

  @doc "The run scope of agent `actor` on the task (a squad leader's with `squad: true`)."
  def run_scope(ctx, actor, opts \\ []) do
    attrs = if opts[:squad], do: %{squad_id: ctx.squad.id}, else: %{}
    {scope, _run} = agent_run_scope(actor, ctx.task, attrs)
    scope
  end

  @doc "Submits a version as `scope` on top of `base`; returns its number."
  def submit(scope, ctx, base, files, extra \\ %{}) do
    {:ok, %{version: n}} =
      TaskSpecs.submit_version(
        scope,
        ctx.ident,
        Map.merge(%{base_version: base, files: files}, extra)
      )

    n
  end

  @doc "`keel/review` reviews `version` with `issues`; returns the review number."
  def review(ctx, version, verdict, issues, actor \\ nil) do
    scope = run_scope(ctx, actor || ctx.review)

    {:ok, %{review: n}} =
      TaskSpecs.submit_review(scope, ctx.ident, %{
        version: version,
        verdict: verdict,
        issues: issues
      })

    n
  end

  @doc "`keel/lead` proposes `version` in its run as `web-team`."
  def propose(ctx, version, summary \\ "R1 settled") do
    {:ok, %{decision: :proposed}} =
      TaskSpecs.finalize(run_scope(ctx, ctx.lead, squad: true), ctx.ident, %{
        version: version,
        summary: summary
      })

    :ok
  end
end
