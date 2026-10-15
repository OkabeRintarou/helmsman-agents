defmodule Helmsman.Runs.PromptSquadTest do
  # add-squads 2.4: the prompt of a run as a squad leader (squad-dispatch
  # "leader 运行的提示词", decision 7).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Agents, Squads, Tasks}
  alias Helmsman.Runs.{Prompt, Run, Spec}
  alias HelmsmanProtocol.RunSpec

  @token "hmr_" <> String.duplicate("a", 52)

  setup do
    ctx = squads_fixture()

    profile(ctx.lead)
    |> Ecto.Changeset.change(instructions: "You are the lead of the web app.")
    |> Repo.update!()

    task = task_fixture(ctx.alice_scope, ctx.project.key, %{title: "Settings page"})
    Map.put(ctx, :task, task)
  end

  defp assigned_run(ctx) do
    {:ok, _} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "web-team"})
    [run] = runs_of(ctx.task.id)
    run |> Ecto.Changeset.change(status: :claimed) |> Repo.update!()
  end

  defp prompt(run) do
    {:ok, %RunSpec{prompt: prompt}} = Spec.build(run, @token, "https://hm.test")
    prompt
  end

  defp bob_name(ctx), do: human_actor(ctx.workspace, ctx.bob).name

  test "the full leader prompt", ctx do
    prompt = ctx |> assigned_run() |> prompt()
    alice = human_actor(ctx.workspace, ctx.alice).name
    ident = ctx.task.ident

    assert prompt =~ ~r/\AYou are the lead of the web app.\n\n## Squad web-team\n/
    assert prompt =~ "In this run you lead the squad web-team. Builds the web app"
    assert prompt =~ "Squad instructions:\nShip small pull requests.\n"

    assert prompt =~
             "- keel/fe (agent; claude, model sonnet, effort high): Writes the frontend — " <>
               "keel/fe works on the web app\n"

    assert prompt =~ "- #{bob_name(ctx)} (person): Decides product questions\n"
    assert prompt =~ "delegate(task_id, to, instructions)"
    assert prompt =~ "You cannot create agents"
    assert prompt =~ "\n\n---\nYou are the agent \"keel/lead\""
    assert prompt =~ "- #{alice} assigned #{ident} to your squad web-team.\n"
  end

  test "snapshot: people, a disabled member and model defaults", ctx do
    {:ok, _} = Agents.disable(ctx.alice_scope, "keel/review")
    profile(ctx.qa) |> Ecto.Changeset.change(model: nil, effort: nil) |> Repo.update!()

    assert Prompt.squad_section(Squads.load(ctx.squad.id), true) ==
             """
             ## Squad web-team
             In this run you lead the squad web-team. Builds the web app

             Squad instructions:
             Ship small pull requests.

             Members:
             - keel/fe (agent; claude, model sonnet, effort high): Writes the frontend — keel/fe works on the web app
             - keel/review (agent; claude, model opus, effort medium; disabled, cannot be delegated now): Reviews — keel/review works on the web app
             - keel/qa (agent; claude, model CLI default, effort CLI default): Tests — keel/qa works on the web app
             - #{bob_name(ctx)} (person): Decides product questions

             How to lead:
             - Hand work on this task to a member agent with delegate(task_id, to, instructions). The member works on the same task, branch and pull request, but only after this run ends: after delegating, finish this run without waiting. Helmsman wakes you with the member's final output when its run ends.
             - Parts that can be delivered on their own can become subtasks: create_task with a member as assignee, grouped with epic and ordered with depends_on (the IDs of the tasks one waits for). Create them all in this run: a subtask whose prerequisites are not done yet starts by itself when they are. Do not create one with start=false to start it later: a run can only change its own task, so you could not. You are woken when they are done or rejected, or when the assignee asks a question.
             - Prefer delegate for code changes: they land in one pull request that is verified once.
             - You cannot create agents or change the squad. If a role is missing, say so in a question on the task; a person can add one.
             - People in the squad cannot be delegated runs; write a question when you need their decision.
             - When the whole goal is met, move the task to done with commits and tests; its requester verifies it. Do not verify it yourself or have a member verify it.\
             """
  end

  test "snapshot: no members, no description, no instructions", ctx do
    {:ok, _} =
      Squads.update(ctx.alice_scope, "web-team", %{
        members: [],
        description: "",
        instructions: ""
      })

    section = Prompt.squad_section(Squads.load(ctx.squad.id), true)

    assert section =~
             ~r/\A## Squad web-team\nIn this run you lead the squad web-team.\n\nMembers:\n- \(none yet\)\n\nHow to lead:\n/
  end

  test "a resumed session: no instructions, the members and how to lead", ctx do
    run = assigned_run(ctx)

    run_fixture(ctx.lead, %{
      task_id: ctx.task.id,
      status: :succeeded,
      session_id: "session-1",
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      squad_id: ctx.squad.id
    })

    prompt = prompt(run)
    refute prompt =~ "You are the lead of the web app."
    refute prompt =~ "Squad instructions"
    refute prompt =~ "Ship small pull requests."
    assert prompt =~ ~r/\A## Squad web-team\n/
    assert prompt =~ "- keel/fe (agent; claude, model sonnet, effort high)"
    assert prompt =~ "How to lead:"
    assert prompt =~ "to your squad web-team."
  end

  test "a mention of the squad", ctx do
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/qa", %{access: "workspace"})
    {:ok, _} = Helmsman.Feedback.add(ctx.carol_scope, ctx.task.ident, %{content: "@web-team ?"})
    [run] = runs_of(ctx.task.id)
    carol = human_actor(ctx.workspace, ctx.carol).name

    prompt = run |> Ecto.Changeset.change(status: :claimed) |> Repo.update!() |> prompt()
    assert prompt =~ "- #{carol} mentioned your squad web-team in #{ctx.task.ident}#1:\n"
    assert prompt =~ "You were asked to reply, not to take over"
  end

  describe "bounds" do
    setup ctx do
      long_grapheme = "e" <> String.duplicate("\u0301", 499)
      four = String.duplicate("😀", 250)
      note = four <> long_grapheme
      assert byte_size(note) <= 2048

      # The profile's limit: 1000 code points.
      description = String.duplicate("😀", 500) <> long_grapheme
      assert length(String.codepoints(description)) == 1000

      members =
        for i <- 1..16 do
          name = "keel/m#{i}"

          managed_agent_fixture(ctx.alice_scope, %{
            name: name,
            runtime_id: ctx.runtime_id,
            access: "workspace",
            model: String.duplicate("m", 128),
            effort: String.duplicate("e", 128),
            description: description
          })

          %{name: name, role_note: note}
        end

      instructions = String.duplicate("😀", 4096)
      assert byte_size(instructions) == 16_384
      squad_description = String.duplicate("😀", 256) <> long_grapheme
      assert byte_size(squad_description) <= 2048

      {:ok, _} =
        Squads.update(ctx.alice_scope, "web-team", %{
          members: members,
          instructions: instructions,
          description: squad_description
        })

      :ok
    end

    test "the squad section stays within 36 KB of valid UTF-8", ctx do
      section = Prompt.squad_section(Squads.load(ctx.squad.id), true)

      assert byte_size(section) <= 36 * 1024
      assert String.valid?(section)

      member_lines = section |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/^- keel\/m\d+ /))
      assert length(member_lines) == 16

      for line <- member_lines do
        assert String.ends_with?(line, "(truncated; list_agents has the full text)")
        assert byte_size(line) <= 1024
      end

      [intro] =
        section |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "In this run"))

      assert String.ends_with?(intro, "…")
    end
  end

  test "a run that is not as a squad gets no section", ctx do
    run = run_fixture(ctx.lead, %{task_id: ctx.task.id, status: :claimed})
    refute prompt(run) =~ "## Squad"
    assert %Run{squad_id: nil} = run
  end
end
