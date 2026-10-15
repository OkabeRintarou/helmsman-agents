defmodule Helmsman.Runs.PromptOrchestrationTest do
  # improve-squad-leader-orchestration: the prompt lines of orchestration
  # (decision 15). 2.4: the `epic_stalled` trigger line.
  use Helmsman.DataCase, async: true

  import Helmsman.OrchestrationFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Repo
  alias Helmsman.Runs.{Run, Spec}
  alias Helmsman.Squads.EpicWatch
  alias HelmsmanProtocol.RunSpec

  @token "hmr_" <> String.duplicate("a", 52)

  setup do
    ctx = orchestration_fixture()
    Repo.update_all(from(r in Run, where: r.status == :running), set: [status: :succeeded])
    ctx
  end

  defp prompt(run) do
    {:ok, %RunSpec{prompt: prompt}} =
      Spec.build(Repo.get!(Run, run.id), @token, "https://hm.test")

    prompt
  end

  defp stalled_run(ctx) do
    :woken = EpicWatch.check(ctx.epic.id)
    run = Repo.one!(from(r in Run, where: r.task_id == ^ctx.epic.id and r.status == :queued))
    run |> Ecto.Changeset.change(status: :claimed) |> Repo.update!()
  end

  test "the epic_stalled line lists the idle steps and their reasons", ctx do
    text = ctx |> stalled_run() |> prompt()
    e = ctx.epic.ident

    assert text =~
             "- Helmsman woke you because #{e} has made no progress: nothing is running on it " <>
               "or its steps, and these steps are idle: #{ctx.s1.ident} (keel/fe: no run), " <>
               "#{ctx.s2.ident} (keel/review: no run), #{ctx.s3.ident} (unassigned). Start, " <>
               "assign or order them (see the Orchestration section), or write a question on " <>
               "#{e} if you need a person. If waiting is right, say why and end the run; " <>
               "Helmsman will not wake you again until something changes."
  end

  test "over 20 idle steps: 20 listed and the rest counted", ctx do
    for n <- 1..20 do
      {:ok, _} =
        Helmsman.Tasks.create(ctx.alice_scope, ctx.project.key, %{
          title: "more #{n}",
          epic: ctx.epic.ident,
          start: false
        })
    end

    run = stalled_run(ctx)
    [%{"idle" => idle, "idle_count" => 23}] = run.triggers
    assert length(idle) == 20
    assert prompt(run) =~ ~s[ (3 more; get_task("#{ctx.epic.ident}") lists all). Start, assign]
  end
end
