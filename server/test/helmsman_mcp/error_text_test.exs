defmodule HelmsmanMCP.ErrorTextTest do
  use ExUnit.Case, async: true

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Tasks.Evidence
  alias Helmsman.Workspaces.Workspace
  alias HelmsmanMCP.{Context, ErrorText}

  defp ctx(args \\ %{}, role \\ :viewer) do
    %Context{
      tool: "identify",
      args: args,
      scope: %Scope{role: role, workspace: %Workspace{slug: "acme"}}
    }
  end

  defp changeset do
    %Actor{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:name, "must be at most %{count} characters", count: 64)
    |> Ecto.Changeset.add_error(:worktree, "is invalid")
  end

  @cases [
    {"viewer", :forbidden, {%{}, :viewer}, "Your role (viewer) cannot do this."},
    {"no role", :forbidden, {%{}, nil}, "You cannot do this."},
    {"forbidden actor", :forbidden, {%{"actor" => "bob/dev"}, :member},
     "Your role (member) cannot do this. The actor argument must name an agent of your own."},
    {"not found", :not_found, {%{}, :viewer}, "Not found in workspace acme."},
    {"name taken", :name_taken, {%{"name" => "alice"}, :viewer},
     "The name alice belongs to a human or to someone else's agent. " <>
       "Pick another agent name, such as team/role (e.g. keel/dev)."},
    {"disabled by name", {:agent_disabled, "keel/dev"}, {%{}, :viewer},
     "The agent keel/dev is disabled. Call identify with another agent name, " <>
       "or ask a human to enable it."},
    {"disabled identify", :agent_disabled, {%{"name" => "keel/dev"}, :viewer},
     "The agent keel/dev is disabled. Call identify with another agent name, " <>
       "or ask a human to enable it."},
    {"invalid kind", {:invalid_kind, "human"}, {%{}, :viewer}, "Only kind=agent is supported."}
  ]

  @tests_reasons [
    {:not_an_object, "tests must be an object"},
    {{:passed, :not_a_boolean}, "passed must be true or false"},
    {{:command, :too_long}, "command is longer than 2000 characters"},
    {{:command, :not_a_string}, "command must be a string"},
    {{:summary, :too_long}, "summary is longer than 2000 characters"},
    {{:summary, :not_a_string}, "summary must be a string"}
  ]

  # designs: add-mcp-task-tools decision 5.
  @task_cases [
                {"task not found", :not_found, {"get_task", %{"task_id" => "bos-99"}, :member},
                 "Task BOS-99 not found in workspace acme."},
                {"feedback not found", :not_found,
                 {"update_feedback", %{"feedback_id" => "BOS-12#9", "content" => "x"}, :member},
                 "Feedback BOS-12#9 not found in workspace acme."},
                {"project not found by key", :not_found,
                 {"get_project", %{"key" => "xx"}, :member},
                 "Project XX not found in workspace acme."},
                {"project not found by project_key", :not_found,
                 {"list_tasks", %{"project_key" => "XX"}, :member},
                 "Project XX not found in workspace acme."},
                {"invalid transition",
                 {:invalid_transition, :done, :cancelled, [:verified, :in_progress]},
                 {"transition_task", %{"task_id" => "BOS-3", "to" => "CANCELLED"}, :member},
                 "Cannot move BOS-3 from DONE to CANCELLED. Allowed: VERIFIED, IN_PROGRESS."},
                {"invalid status",
                 {:invalid_status, "doing",
                  [:new, :in_progress, :done, :verified, :rejected, :cancelled]},
                 {"transition_task", %{"task_id" => "BOS-3", "to" => "doing"}, :member},
                 ~s(Unknown status "doing". Use one of: NEW, IN_PROGRESS, DONE, VERIFIED, REJECTED, CANCELLED.)},
                {"self verify", {:self_verify_requires_tests, "keel/dev"},
                 {"transition_task", %{"task_id" => "BOS-3"}, :member},
                 "You (keel/dev) are the assignee. Pass tests={passed: true, ...} or let the requester verify."},
                {"stale", :stale, {"update_task", %{"task_id" => "BOS-3"}, :member},
                 "BOS-3 was changed by someone else since you read it. " <>
                   "Call get_task to see the latest version (lock_version), then retry."},
                {"project archived", :project_archived,
                 {"create_task", %{"project_key" => "bos"}, :member},
                 "Project BOS is archived and cannot take new tasks. " <>
                   "An admin can restore it with update_project(archived: false)."},
                {"superseded", {:superseded, "BOS-12#5"},
                 {"update_feedback", %{"feedback_id" => "BOS-12#3"}, :member},
                 "BOS-12#3 was already revised; the current version is BOS-12#5. Revise that one instead."},
                {"invalid commits", {:invalid_commits, "xyz"},
                 {"transition_task", %{"task_id" => "BOS-1"}, :member},
                 "Invalid commit hashes: xyz. Each must be 7-64 hexadecimal characters."},
                {"comment too long", {:invalid_comment, :too_long},
                 {"transition_task", %{"task_id" => "BOS-1"}, :member},
                 "comment is too long (max 10000 characters). Put details in a feedback instead."},
                {"no identity", :no_identity, {"list_my_tasks", %{}, :member},
                 "You have no identity in this session. Call identify(name, project, worktree) first."},
                {"no actor", :no_actor, {"add_feedback", %{}, :member},
                 "You have no identity in this session. Call identify(name, project, worktree) first."},
                {"revise someone else's", :forbidden,
                 {"update_feedback", %{"feedback_id" => "BOS-1#2"}, :member},
                 "You can only revise feedback written by you or your own agents. Add a new feedback instead."},
                {"revise as a viewer", :forbidden,
                 {"update_feedback", %{"feedback_id" => "BOS-1#2"}, :viewer},
                 "Your role (viewer) cannot do this."},
                {"forbidden author", :forbidden,
                 {"add_feedback", %{"author" => "bob/dev"}, :member},
                 "Your role (member) cannot do this. The author argument must name an agent of your own."}
              ] ++
                for(
                  {reason, phrase} <- @tests_reasons,
                  do:
                    {"invalid tests #{inspect(reason)}", {:invalid_tests, reason},
                     {"transition_task", %{"task_id" => "BOS-1"}, :member},
                     "Invalid tests: #{phrase}. Pass {command, passed: true/false, summary}."}
                )

  for {label, reason, {tool, args, role}, text} <- @task_cases do
    test label do
      ctx = %{ctx(unquote(Macro.escape(args)), unquote(role)) | tool: unquote(tool)}
      assert {:ok, text} = ErrorText.format(unquote(Macro.escape(reason)), ctx)
      assert text == unquote(text)
      refute text =~ "Internal error"
    end
  end

  test "every Evidence reason has a test case" do
    # Every `{:invalid_tests, _}` reason Helmsman.Tasks.Evidence returns.
    reasons =
      for input <- [
            "x",
            %{passed: "yes"},
            %{passed: true, command: 1, summary: "s"},
            %{passed: true, command: String.duplicate("a", 2001), summary: "s"},
            %{passed: true, command: "c", summary: 1},
            %{passed: true, command: "c", summary: String.duplicate("a", 2001)}
          ] do
        {:error, {:invalid_tests, reason}} = Evidence.normalize(%{tests: input})
        reason
      end

    assert Enum.sort(reasons) == Enum.sort(Enum.map(@tests_reasons, &elem(&1, 0)))
  end

  for {label, reason, {args, role}, text} <- @cases do
    test label do
      ctx = ctx(unquote(Macro.escape(args)), unquote(role))
      assert ErrorText.format(unquote(Macro.escape(reason)), ctx) == {:ok, unquote(text)}
    end
  end

  test "a changeset lists one field per line" do
    assert ErrorText.format(changeset(), ctx()) ==
             {:ok, "name: must be at most 64 characters\nworktree: is invalid"}
  end

  # add-rest-api decision 5: REST maps the same reasons
  # (HelmsmanWeb.API.ErrorMapperTest).
  test "every domain error reason has a text" do
    for {label, reason, tool} <- Helmsman.DomainErrorReasons.all() do
      ctx = %{ctx(%{}, :member) | tool: tool || "identify"}
      assert {:ok, text} = ErrorText.format(reason, ctx), "no text for #{label}"
      assert text != "", label
    end
  end

  test "an unknown reason has no text" do
    assert ErrorText.format(:whatever, ctx()) == :error
  end

  test "the internal error text carries the reference" do
    assert ErrorText.internal("0a1b2c3d") ==
             "Internal error (ref 0a1b2c3d). Try again later; if it keeps happening, tell a human."
  end

  test "every text is ASCII" do
    texts =
      [ErrorText.internal("0a1b2c3d") | Enum.map(@cases ++ @task_cases, &elem(&1, 3))] ++
        [elem(ErrorText.format(changeset(), ctx()), 1)]

    for text <- texts, do: assert(text =~ ~r/\A[\x20-\x7e\n]+\z/)
  end
end
