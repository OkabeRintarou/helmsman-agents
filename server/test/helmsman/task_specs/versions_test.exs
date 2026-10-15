defmodule Helmsman.TaskSpecs.VersionsTest do
  # add-spec-workflow 1.3: task-specs 「任务的规格」「版本与文件」「规格的状态」
  # (decisions 1, 3, 6).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{Events, Repo, TaskSpecs}
  alias Helmsman.TaskSpecs.{Blob, Event, ReviewRequest, Spec, Version}

  setup do
    ctx = specs_fixture()
    Map.put(ctx, :ident, ctx.task.ident)
  end

  defp submit(scope, ident, base, files, extra \\ %{}),
    do:
      TaskSpecs.submit_version(
        scope,
        ident,
        Map.merge(%{base_version: base, files: files}, extra)
      )

  defp spec!(ctx), do: Repo.get_by!(Spec, task_id: ctx.task.id)

  describe "任务的规格" do
    test "an empty spec gets the task ID in lower case", ctx do
      assert {:ok, summary} = TaskSpecs.update(ctx.alice_scope, ctx.ident, %{})
      assert summary.change_id == String.downcase(ctx.ident)
      assert summary.status == :draft
      assert summary.latest_version == 0
      assert [%{action: "created", data: %{"change_id" => _}}] = Repo.all(Event)
    end

    test "the first submission creates the spec with its change_id", ctx do
      {scope, run} = agent_run_scope(ctx.fe, ctx.task)

      assert {:ok, %{version: 1}} =
               submit(scope, ctx.ident, 0, spec_files(), %{change_id: "add-settings-page"})

      spec = spec!(ctx)
      assert spec.change_id == "add-settings-page"
      assert spec.latest_version == 1

      assert %Version{author_id: author, source_run_id: run_id} =
               Repo.get_by!(Version, spec_id: spec.id)

      assert {author, run_id} == {ctx.fe.id, run.id}
    end

    test "a taken change_id is a changeset error and changes nothing", ctx do
      other = task_fixture(ctx.alice_scope, ctx.project.key)
      spec_fixture(ctx.alice_scope, other.ident, versions: 0, change_id: "add-settings-page")
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 0)

      assert {:error, %Ecto.Changeset{errors: [change_id: {"has already been taken", _}]}} =
               TaskSpecs.update(ctx.alice_scope, ctx.ident, %{change_id: "add-settings-page"})

      assert spec!(ctx).change_id == String.downcase(ctx.ident)
    end

    test "changing the change_id is audited", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 0)

      assert {:ok, %{change_id: "add-x"}} =
               TaskSpecs.update(ctx.alice_scope, ctx.ident, %{change_id: "add-x"})

      assert %Event{data: %{"from" => _, "to" => "add-x"}} =
               Repo.get_by!(Event, action: "change_id_changed")
    end

    test "a malformed change_id", ctx do
      assert {:error, %Ecto.Changeset{errors: [change_id: _]}} =
               TaskSpecs.update(ctx.alice_scope, ctx.ident, %{change_id: "Bad_Id"})
    end
  end

  describe "版本与文件" do
    test "only the changed files: the rest carries over", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident)
      new_spec = spec_files(tag: "new")["specs/settings/spec.md"]

      assert {:ok, %{version: 2, files: files}} =
               submit(
                 ctx.alice_scope,
                 ctx.ident,
                 1,
                 [%{path: "specs/settings/spec.md", content: new_spec}],
                 %{
                   remove: ["tasks.md"]
                 }
               )

      assert Enum.map(files, & &1.path) == ["proposal.md", "specs/settings/spec.md"]
      spec = spec!(ctx)
      v2 = TaskSpecs.version_files(spec, 2)
      assert v2["proposal.md"] == spec_files()["proposal.md"]
      assert v2["specs/settings/spec.md"] == new_spec
      refute Map.has_key?(v2, "tasks.md")
    end

    test "a stale base version", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 2)

      assert {:error, {:spec, :stale_version, 2}} =
               submit(ctx.alice_scope, ctx.ident, 1, spec_files(tag: "x"))

      assert spec!(ctx).latest_version == 2
    end

    test "two first submissions at once: one stale_version", ctx do
      parent = self()

      results =
        for tag <- ["a", "b"] do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())
            submit(ctx.alice_scope, ctx.ident, 0, spec_files(tag: tag))
          end)
        end
        |> Enum.map(&Task.await/1)

      assert Enum.sort_by(results, &elem(&1, 0)) |> Enum.map(&elem(&1, 0)) == [:error, :ok]
      assert {:error, {:spec, :stale_version, 1}} in results
      assert spec!(ctx).latest_version == 1
    end

    test "paths that are not allowed", ctx do
      assert {:error, {:spec, :invalid_files, problems}} =
               submit(ctx.alice_scope, ctx.ident, 0, %{
                 "specs/../secrets.md" => "x",
                 "notes.md" => "y",
                 "proposal.md" => "ok"
               })

      assert problems |> Enum.map(& &1.path) |> Enum.sort() == ["notes.md", "specs/../secrets.md"]
      refute Repo.exists?(Spec)
    end

    test "nested capabilities up to three segments", ctx do
      files = %{"specs/a/b/c/spec.md" => "x", "specs/a/b/c/d/spec.md" => "y"}

      assert {:error, {:spec, :invalid_files, [%{path: "specs/a/b/c/d/spec.md"}]}} =
               submit(ctx.alice_scope, ctx.ident, 0, files)
    end

    test "sizes in bytes: 256 KB of Chinese passes, one byte more does not", ctx do
      # "设" is 3 bytes.
      ok = String.duplicate("设", div(256 * 1024, 3)) <> "a"
      assert byte_size(ok) == 256 * 1024

      assert {:ok, %{version: 1}} =
               submit(ctx.alice_scope, ctx.ident, 0, Map.put(spec_files(), "design.md", ok))

      assert {:error, {:spec, :invalid_files, [%{path: "design.md"}]}} =
               submit(ctx.alice_scope, ctx.ident, 1, %{"design.md" => ok <> "b"})
    end

    test "NUL and invalid UTF-8 are rejected", ctx do
      assert {:error, {:spec, :invalid_files, problems}} =
               submit(ctx.alice_scope, ctx.ident, 0, %{
                 "proposal.md" => "a\0b",
                 "tasks.md" => <<0xFF>>
               })

      assert length(problems) == 2
    end

    test "the same content in two versions is one blob", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident)
      assert {:ok, _} = submit(ctx.alice_scope, ctx.ident, 1, %{"design.md" => "## Context\n"})
      spec = spec!(ctx)
      # proposal, tasks, spec.md (shared) and design.md.
      assert Repo.aggregate(from(b in Blob, where: b.spec_id == ^spec.id), :count) == 4
    end

    test "no changes", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident)
      assert {:error, {:spec, :no_changes}} = submit(ctx.alice_scope, ctx.ident, 1, spec_files())
      assert {:error, {:spec, :no_changes}} = submit(ctx.alice_scope, ctx.ident, 1, %{})
    end

    test "a dry run writes nothing and notifies nobody", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident)
      Events.subscribe(Events.topic(:task, ctx.task.id))

      assert {:ok, %{version: nil, files: files, validation: %{valid: false, errors: [_ | _]}}} =
               submit(ctx.alice_scope, ctx.ident, 1, %{"tasks.md" => "no items"}, %{dry_run: true})

      assert Enum.find(files, &(&1.path == "tasks.md")).bytes == 8
      assert spec!(ctx).latest_version == 1
      assert Repo.aggregate(Version, :count) == 1
      refute_receive {:spec_changed, _}
    end

    test "a dry run of a first version creates no spec", ctx do
      assert {:ok, %{version: nil, validation: %{valid: true}}} =
               submit(ctx.alice_scope, ctx.ident, 0, spec_files(), %{dry_run: true})

      refute Repo.exists?(Spec)
    end

    test "a submission records the validation, note and broadcasts", ctx do
      Events.subscribe(Events.topic(:task, ctx.task.id))

      assert {:ok, %{version: 1, validation: %{valid: false}}} =
               submit(ctx.alice_scope, ctx.ident, 0, spec_files(invalid: true), %{note: "first"})

      assert %Version{
               valid: false,
               note: "first",
               validation: %{"errors" => [%{"rule" => "requirement_no_scenario"}]}
             } =
               Repo.one!(Version)

      task_id = ctx.task.id
      assert_receive {:spec_changed, ^task_id}
    end

    test "a note over 4 KB", ctx do
      assert {:error, {:spec, :invalid_params, %{field: :note}}} =
               submit(ctx.alice_scope, ctx.ident, 0, spec_files(), %{
                 note: String.duplicate("x", 4097)
               })
    end

    test "a finalized or abandoned spec is closed", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident)
      {:ok, _} = TaskSpecs.abandon(ctx.alice_scope, ctx.ident, %{reason: "not needed"})

      assert {:error, {:spec, :closed, :abandoned}} =
               submit(ctx.alice_scope, ctx.ident, 1, spec_files(tag: "x"))
    end
  end

  describe "规格的状态" do
    setup ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 2)
      :ok
    end

    test "a new version supersedes pending requests: back to draft", ctx do
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, ["keel/review"])
      assert spec!(ctx).status == :in_review

      {scope, _run} = agent_run_scope(ctx.fe, ctx.task)
      assert {:ok, %{version: 3}} = submit(scope, ctx.ident, 2, spec_files(tag: "v3"))

      assert %ReviewRequest{status: :cancelled, close_reason: :superseded, closed_at: %DateTime{}} =
               Repo.one!(ReviewRequest)

      assert spec!(ctx).status == :draft

      assert ["version_submitted", "review_request_closed"] ==
               Repo.all(
                 from(e in Event, where: e.number > 4, order_by: e.number, select: e.action)
               )
    end

    test "a new version withdraws the proposal", ctx do
      {scope, _run} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})

      {:ok, %{decision: :proposed}} =
        TaskSpecs.finalize(scope, ctx.ident, %{version: 2, summary: "ok"})

      assert spec!(ctx).status == :pending_approval

      assert {:ok, %{version: 3}} = submit(ctx.alice_scope, ctx.ident, 2, spec_files(tag: "v3"))
      spec = spec!(ctx)
      assert spec.status == :draft
      assert is_nil(spec.proposal_version)

      assert %Event{version: 2} = Repo.get_by!(Event, action: "proposal_withdrawn")
    end
  end

  test "viewers cannot write; runs only their own task", ctx do
    {_carol, viewer} = member_scope_fixture(ctx.workspace, :viewer)
    assert {:error, :forbidden} = submit(viewer, ctx.ident, 0, spec_files())

    other = task_fixture(ctx.alice_scope, ctx.project.key)
    {scope, _run} = agent_run_scope(ctx.fe, ctx.task)
    assert {:error, :forbidden} = submit(scope, other.ident, 0, spec_files())
  end
end
