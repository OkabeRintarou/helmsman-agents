defmodule Helmsman.Feedback do
  @moduledoc """
  Task feedback (designs/06): immutable, append-only Markdown records
  between people and agents. Members and above (and their agents) add and
  revise; every member reads.

  Every write locks the task row first (designs/01 §4: the task row covers
  its feedback) and, in the same transaction, keeps the task's
  `feedback_seq` (last number given out), `feedback_count` (active records)
  and `open_question` in line with the records. Numbers are therefore
  gap-free and never reused, and a rollback gives them back.

  A revision appends a record that takes the place (`thread_seq`) of the
  one it revises and supersedes it; only its author, or another identity
  of the same user, may revise a record, never one the system wrote.

  After the commit, every addition or revision broadcasts
  `{:feedback_added, view}` on the task topic and
  `{:task_updated, summary}` on the project topic.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Dispatch.{Continuation, Targets}
  alias Helmsman.Events
  alias Helmsman.Feedback.{Entry, Id, Mentions, Replies}
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs.{Outcome, Steering}
  alias Helmsman.Squads.EpicWatch
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  @type input :: %{
          required(:kind) => Entry.kind() | nil,
          required(:content) => String.t(),
          optional(:reply_to) => String.t() | nil,
          optional(:reply_to_seq) => pos_integer() | nil,
          optional(:reply_root_seq) => pos_integer() | nil
        }
  @type actor_ref :: %{name: String.t(), kind: String.t()}
  @type dispatch_item :: %{
          agent: String.t() | nil,
          trigger: String.t(),
          result: String.t(),
          reason: String.t() | nil,
          run_id: pos_integer() | nil,
          steer_run_id: pos_integer() | nil
        }
  @type steer_view :: %{
          run_id: pos_integer(),
          agent: String.t(),
          sent_at: DateTime.t(),
          acked_at: DateTime.t() | nil
        }
  @type view :: %{
          id: String.t(),
          seq: pos_integer(),
          thread_seq: pos_integer(),
          reply_to: String.t() | nil,
          reply_root: String.t() | nil,
          target: map() | nil,
          kind: String.t(),
          content: String.t(),
          author: actor_ref() | nil,
          mentions: [String.t()],
          status: String.t(),
          supersedes: String.t() | nil,
          superseded_by: String.t() | nil,
          dispatch: [dispatch_item()],
          steer: steer_view() | nil,
          at: DateTime.t()
        }

  ## Adding

  @doc """
  Adds feedback to the task `ident` as `scope.actor` (`:add_feedback`).

  `attrs`: `kind` (`comment`, the default, `review`, `question` or
  `answer`) and `content` (Markdown, not blank, at most 64 KB; checked
  before the transaction, so invalid input takes no lock and no number).

  Mentions, answers and the assignee's questions trigger runs
  (`Helmsman.Dispatch.Continuation`) in the same transaction; their
  outcomes are kept on the record (`dispatch` in `view/1`). Returns the new
  entry (`load/2` done); `{:error, :busy}` when the trigger targets kept
  changing (`Helmsman.Dispatch.Targets`).

  `steer_run_id` (optional; people only) names a run of this task to send
  the record into while it runs (`Helmsman.Runs.Steering`,
  `add-run-steering` decision 3); field errors on it when it is not a
  positive integer, the actor is not a person, or the run is not one of
  this task's.

  `reply_to` optionally names an existing feedback ID in this task. The
  physical target and the root revision thread are preserved on revisions;
  reads resolve the target's current version for its summary and link.
  """
  @spec add(Scope.t(), String.t(), map()) ::
          {:ok, Entry.t()} | {:error, Changeset.t() | :forbidden | :not_found | :no_actor}
  def add(%Scope{actor: nil}, _ident, _attrs), do: {:error, :no_actor}

  def add(%Scope{workspace: %Workspace{}} = scope, ident, attrs)
      when is_binary(ident) and is_map(attrs) do
    {steer, attrs} = pop_steer(attrs)
    {reply_to, attrs} = Map.pop(attrs, :reply_to, attrs["reply_to"])
    attrs = Map.delete(attrs, "reply_to")

    with {:ok, input} <- normalize(attrs),
         {:ok, steer_run_id} <- Steering.check_request(scope, steer),
         :ok <- check_reply_type(reply_to),
         {:ok, ident, _key, _seq} <- Ident.parse(ident) do
      input = Map.put(input, :reply_to, reply_to)

      Workspaces.write_transaction(
        scope,
        :add_feedback,
        &add_locked(&1, ident, input, steer_run_id)
      )
    end
  end

  defp check_reply_type(nil), do: :ok
  defp check_reply_type(id) when is_binary(id), do: :ok
  defp check_reply_type(_id), do: {:error, Replies.error("must be a feedback ID")}

  defp pop_steer(attrs) do
    {atom, attrs} = Map.pop(attrs, :steer_run_id)
    {string, attrs} = Map.pop(attrs, "steer_run_id")
    {atom || string, attrs}
  end

  # Lock order: maintenance lock, membership row (write_transaction),
  # trigger targets (with the steered run's agent), task row
  # (`Helmsman.Dispatch.Targets`).
  defp add_locked(scope, ident, input, steer_run_id) do
    workspace_id = scope.workspace.id

    with {:ok, task, {plan, steer, resolved}} <-
           Targets.with_locked(
             workspace_id,
             fn ->
               Continuation.guess(workspace_id, ident, input.content) ++
                 Steering.guess(workspace_id, steer_run_id)
             end,
             fn -> lock_task(workspace_id, ident) end,
             &plan_add(scope, &1, input, steer_run_id)
           ),
         :ok <- Policy.authorize(scope, :write_task, task),
         {:ok, input} <- resolved,
         {:ok, run} <- steer do
      {:ok, {entry, task}} =
        insert_locked(task, scope, input, mentions: plan.feedback.mentions, notify: false)

      outcomes = Steering.run_feedback(scope, plan, task, entry, run)
      {entry, task} = finish_locked(task, entry, outcomes)
      notify_task(task)
      {:ok, entry}
    end
  end

  defp plan_add(scope, task, input, steer_run_id) do
    case Replies.resolve(task, input) do
      {:ok, input} ->
        {targets, plan} = Continuation.plan_feedback(scope, task, input, nil)
        steer = Steering.target(task, steer_run_id)
        {targets ++ Steering.target_ids(steer), {plan, steer, {:ok, input}}}

      {:error, _} = error ->
        {[], {nil, nil, error}}
    end
  end

  @doc """
  Validates feedback input (`kind`, `content`; atom or string keys)
  without touching the database. `kind` is `nil` when not given. A
  `steer_run_id` and `reply_to` are refused: only `add/3` takes them.
  """
  @spec normalize(map()) :: {:ok, input()} | {:error, Changeset.t()}
  def normalize(attrs) when is_map(attrs) do
    changeset = Entry.changeset(%Entry{kind: nil}, attrs)

    changeset =
      if is_nil(attrs[:steer_run_id] || attrs["steer_run_id"]),
        do: changeset,
        else: Changeset.add_error(changeset, :steer_run_id, "can only be given with new feedback")

    changeset =
      if is_nil(Map.get(attrs, :reply_to, attrs["reply_to"])),
        do: changeset,
        else: Changeset.add_error(changeset, :reply_to, "can only be given with new feedback")

    if changeset.valid? do
      {:ok,
       %{
         kind: Changeset.get_field(changeset, :kind),
         content: Changeset.get_field(changeset, :content)
       }}
    else
      {:error, changeset}
    end
  end

  @doc """
  Inserts feedback in `task`, whose row the caller has locked `FOR UPDATE`
  inside a transaction, and updates the task's feedback columns. `input`
  comes from `normalize/1` (a `nil` kind is `comment`). No authorization:
  the caller has authorized its own action. Records `scope.run` as the
  source of a run token's write. Options: `fallback: true` and
  `source_run_id` (`Helmsman.Runs.SideEffects`), `mentions` (already
  resolved) and `notify: false` (the caller calls `finish_locked/3`).
  Registers the `{:feedback_added, view}` notification on the task topic
  only; the caller notifies the project topic. Triggers nothing.

  Returns the new entry and the updated task.
  """
  @spec insert_locked(Task.t(), Scope.t(), input(), keyword()) :: {:ok, {Entry.t(), Task.t()}}
  def insert_locked(
        %Task{} = task,
        %Scope{actor: %Actor{} = actor} = scope,
        %{content: content} = input,
        opts \\ []
      ) do
    seq = task.feedback_seq + 1

    entry =
      Repo.insert!(
        Entry.new(
          workspace_id: task.workspace_id,
          task_id: task.id,
          seq: seq,
          thread_seq: seq,
          reply_to_seq: input[:reply_to_seq],
          reply_root_seq: input[:reply_root_seq],
          author_id: actor.id,
          kind: input[:kind] || :comment,
          content: content,
          mentions:
            Keyword.get_lazy(opts, :mentions, fn ->
              resolve_mentions(task.workspace_id, content)
            end),
          source_run_id: Keyword.get(opts, :source_run_id, source_run_id(scope)),
          fallback: Keyword.get(opts, :fallback, false)
        )
      )

    task = refresh_counters(task, seq)
    entry = entry |> load(task.ident) |> hd()
    if Keyword.get(opts, :notify, true), do: notify_entry(task, entry)
    # `improve-squad-leader-orchestration` decision 11: a person writing on
    # an epic led by a squad, or a step, starts a new progress cycle.
    EpicWatch.after_feedback(task, actor)
    {:ok, {entry, task}}
  end

  @doc """
  Writes the trigger outcomes a new record caused onto it, in the
  transaction that inserted it (`add-continuation-triggers` decision 10),
  then registers its `{:feedback_added, view}` notification. Returns the
  entry, loaded, and the task read again when a trigger may have written
  to it (a refused trigger chain adds a system comment).
  """
  @spec finish_locked(Task.t(), Entry.t(), [Outcome.t()]) :: {Entry.t(), Task.t()}
  def finish_locked(%Task{} = task, %Entry{} = entry, []) do
    notify_entry(task, entry)
    {entry, task}
  end

  def finish_locked(%Task{} = task, %Entry{} = entry, outcomes) do
    dispatch = Enum.map(outcomes, &Outcome.stored/1)
    {1, _} = Repo.update_all(where(Entry, id: ^entry.id), set: [dispatch: dispatch])
    task = Repo.reload!(task)
    entry = %{entry | dispatch: dispatch} |> load(task.ident) |> hd()
    notify_entry(task, entry)
    {entry, task}
  end

  ## Revising

  @doc """
  Revises the feedback `id` (`KEY-N#S`) with new `content` and, optionally,
  a new `kind` (`:revise_feedback`, which checks the author rule).

  Appends a record by `scope.actor` in the place of the old one, which
  becomes superseded and points to it. Triggers as `add/3`, counting only
  the mentions the old record did not have. Returns the new entry.

  Errors: a changeset for invalid input, `:not_found`, `:forbidden`,
  `:no_actor`, `:busy` and `{:superseded, latest_id}` when the record was already
  revised (`latest_id` being the active record of its chain).
  """
  @spec revise(Scope.t(), String.t(), map()) ::
          {:ok, Entry.t()}
          | {:error,
             Changeset.t() | :forbidden | :not_found | :no_actor | {:superseded, String.t()}}
  def revise(%Scope{actor: nil}, _id, _attrs), do: {:error, :no_actor}

  def revise(%Scope{workspace: %Workspace{id: workspace_id}} = scope, id, attrs)
      when is_binary(id) and is_map(attrs) do
    with {:ok, input} <- normalize(attrs),
         {:ok, ident, seq} <- Id.parse(id),
         # The author never changes: reading it before the transaction is
         # safe, and lets write_transaction authorize against it.
         {:ok, %Entry{author: author}} <- fetch(workspace_id, ident, seq) do
      Workspaces.write_transaction(
        scope,
        :revise_feedback,
        author,
        &revise_locked(&1, ident, seq, input)
      )
    end
  end

  # Lock order: trigger targets, the task row, then the record.
  defp revise_locked(scope, ident, seq, input) do
    workspace_id = scope.workspace.id

    with {:ok, task, plan} <-
           Targets.with_locked(
             workspace_id,
             fn -> Continuation.guess(workspace_id, ident, input.content) end,
             fn -> lock_task(workspace_id, ident) end,
             &Continuation.plan_feedback(scope, &1, input, entry_at(&1, seq))
           ),
         :ok <- Policy.authorize(scope, :write_task, task),
         {:ok, old} <- lock_entry(task, seq),
         :ok <- check_active(task, old) do
      {entry, task} = insert_revision(task, old, scope, input, plan.feedback.mentions)
      outcomes = Continuation.run_feedback(scope, plan, task, entry)
      {entry, task} = finish_locked(task, entry, outcomes)
      notify_task(task)
      {:ok, entry}
    end
  end

  # Read under the task row lock, which every revision takes first.
  defp entry_at(task, seq), do: Repo.get_by(Entry, task_id: task.id, seq: seq)

  defp lock_entry(task, seq) do
    query =
      from(f in Entry, where: f.task_id == ^task.id and f.seq == ^seq, lock: "FOR UPDATE")

    case Repo.one(query) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp check_active(_task, %Entry{status: :active}), do: :ok

  defp check_active(task, %Entry{superseded_by_id: next_id}),
    do: {:error, {:superseded, Id.build(task.ident, latest_seq(next_id))}}

  # Follows the chain to its active record. Chains are short and stable
  # under the task row lock.
  defp latest_seq(id) do
    case Repo.one!(from(f in Entry, where: f.id == ^id, select: {f.seq, f.superseded_by_id})) do
      {seq, nil} -> seq
      {_seq, next_id} -> latest_seq(next_id)
    end
  end

  defp insert_revision(task, old, scope, input, mentions) do
    seq = task.feedback_seq + 1

    entry =
      Repo.insert!(
        Entry.new(
          workspace_id: task.workspace_id,
          task_id: task.id,
          seq: seq,
          thread_seq: old.thread_seq,
          reply_to_seq: old.reply_to_seq,
          reply_root_seq: old.reply_root_seq,
          author_id: scope.actor.id,
          kind: input.kind || old.kind,
          content: input.content,
          mentions: mentions,
          supersedes_id: old.id,
          source_run_id: source_run_id(scope)
        )
      )

    # A superseded record is never found (designs/06 §1).
    {1, _} =
      Repo.update_all(where(Entry, id: ^old.id),
        set: [status: :superseded, superseded_by_id: entry.id, search: nil]
      )

    task = refresh_counters(task, seq)
    EpicWatch.after_feedback(task, scope.actor)
    {entry |> load(task.ident) |> hd(), task}
  end

  ## Shared write steps

  # Lock order: maintenance lock, membership row (write_transaction), task
  # row (designs/01 §4).
  defp lock_task(workspace_id, ident) do
    query =
      from(t in Task,
        where: t.workspace_id == ^workspace_id and t.ident == ^ident,
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  # The run of a run token's write (designs/13, decision 12).
  defp source_run_id(%Scope{via: :run, run: %{id: id}}), do: id
  defp source_run_id(_scope), do: nil

  defp resolve_mentions(workspace_id, content),
    do: Mentions.resolve(workspace_id, Mentions.extract(content))

  # Recomputes the active count and the open question from the records.
  # Not a user edit: `lock_version` stays.
  defp refresh_counters(task, seq) do
    count =
      Repo.aggregate(
        from(f in Entry, where: f.task_id == ^task.id and f.status == :active),
        :count
      )

    task
    |> Changeset.change(
      feedback_seq: seq,
      feedback_count: count,
      open_question: open_question?(task.id)
    )
    |> Repo.update!()
  end

  # The task waits for an answer when, among its active questions and
  # answers, the last in the timeline is a question. Each thread has one
  # active record, so `thread_seq` orders them strictly.
  defp open_question?(task_id) do
    query =
      from(f in Entry,
        where: f.task_id == ^task_id and f.status == :active and f.kind in [:question, :answer],
        order_by: [desc: f.thread_seq],
        limit: 1,
        select: f.kind
      )

    Repo.one(query) == :question
  end

  ## Reading

  @doc """
  Lists every feedback record of the task `ident`, superseded ones
  included, by number (`:read_tasks`).
  """
  @spec list(Scope.t(), String.t()) :: {:ok, [Entry.t()]} | {:error, :forbidden | :not_found}
  def list(%Scope{workspace: %Workspace{id: workspace_id}} = scope, ident)
      when is_binary(ident) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, ident, _key, _seq} <- Ident.parse(ident),
         %Task{} = task <-
           Repo.one(from(t in Task, where: t.workspace_id == ^workspace_id and t.ident == ^ident)) do
      {:ok, for_task(task)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Returns the IDs (`KEY-N#S`) of the task's active records that `scope`
  may revise (`:read_tasks` to ask; each record by
  `Helmsman.Policy.authorize(scope, :revise_feedback, author)`): an
  empty set for viewers. One query for the task, one for its active
  records with their authors.
  """
  @spec revisable_ids(Scope.t(), String.t()) ::
          {:ok, MapSet.t(String.t())} | {:error, :forbidden | :not_found}
  def revisable_ids(%Scope{workspace: %Workspace{id: workspace_id}} = scope, ident)
      when is_binary(ident) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, ident, _key, _seq} <- Ident.parse(ident),
         %Task{} = task <-
           Repo.one(from(t in Task, where: t.workspace_id == ^workspace_id and t.ident == ^ident)) do
      ids =
        from(f in Entry,
          join: a in assoc(f, :author),
          where: f.task_id == ^task.id and f.status == :active,
          select: {f.seq, a}
        )
        |> Repo.all()
        |> Enum.filter(fn {_seq, author} ->
          Policy.authorize(scope, :revise_feedback, author) == :ok
        end)
        |> MapSet.new(fn {seq, _author} -> Id.build(task.ident, seq) end)

      {:ok, ids}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Gets one feedback record by ID (`KEY-N#S`, any case) (`:read_tasks`).
  Malformed IDs and records of other workspaces are `:not_found`.
  """
  @spec get(Scope.t(), String.t()) :: {:ok, Entry.t()} | {:error, :forbidden | :not_found}
  def get(%Scope{workspace: %Workspace{id: workspace_id}} = scope, id) when is_binary(id) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, ident, seq} <- Id.parse(id),
         {:ok, entry} <- fetch(workspace_id, ident, seq) do
      {:ok, entry |> load(ident) |> hd()}
    end
  end

  defp fetch(workspace_id, ident, seq) do
    query =
      from(f in Entry,
        join: t in Task,
        on: t.id == f.task_id,
        where: t.workspace_id == ^workspace_id and t.ident == ^ident and f.seq == ^seq,
        preload: :author
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc """
  Every feedback record of `task` by number, loaded for `view/1`. Used by
  `Helmsman.Tasks` for the task detail.
  """
  @spec for_task(Task.t()) :: [Entry.t()]
  def for_task(%Task{} = task) do
    from(f in Entry, where: f.task_id == ^task.id, order_by: [asc: f.seq])
    |> Repo.all()
    |> load(task.ident)
  end

  @doc """
  Loads what `view/1` needs into `entries` of the task `ident`: the
  author, the mentioned names, the numbers of the linked records and the
  steering state (`Helmsman.Runs.Steering.views/1`) and reply targets. At most five
  queries, whatever the number of entries.
  """
  @spec load([Entry.t()] | Entry.t(), String.t()) :: [Entry.t()]
  def load(%Entry{} = entry, ident), do: load([entry], ident)
  def load([], _ident), do: []

  def load(entries, ident) when is_list(entries) do
    entries = Repo.preload(entries, :author)

    names =
      case entries |> Enum.flat_map(&(&1.mentions ++ dispatch_agents(&1))) |> Enum.uniq() do
        [] -> %{}
        ids -> Map.new(Repo.all(from(a in Actor, where: a.id in ^ids, select: {a.id, a.name})))
      end

    targets = Replies.targets(entries, ident)
    seqs = linked_seqs(entries)
    steers = entries |> Enum.map(& &1.id) |> Steering.views()

    Enum.map(entries, fn entry ->
      %{
        entry
        | task_ident: ident,
          mention_names: entry.mentions |> Enum.map(&names[&1]) |> Enum.reject(&is_nil/1),
          dispatch_view: Enum.map(entry.dispatch, &dispatch_view(&1, names)),
          supersedes_seq: seqs[entry.supersedes_id],
          superseded_by_seq: seqs[entry.superseded_by_id],
          steer: steers[entry.id],
          target: targets[{entry.task_id, entry.reply_to_seq}]
      }
    end)
  end

  defp dispatch_agents(%Entry{dispatch: dispatch}),
    do: dispatch |> Enum.map(& &1["agent_id"]) |> Enum.reject(&is_nil/1)

  defp dispatch_view(item, names) do
    %{
      agent: names[item["agent_id"]],
      trigger: item["trigger"],
      result: item["result"],
      reason: item["reason"],
      run_id: item["run_id"],
      steer_run_id: item["steer_run_id"],
      squad: item["squad"],
      refused: item["refused"]
    }
  end

  # Numbers of the records the entries link to; those among the entries
  # need no query.
  defp linked_seqs(entries) do
    known = Map.new(entries, &{&1.id, &1.seq})

    missing =
      entries
      |> Enum.flat_map(&[&1.supersedes_id, &1.superseded_by_id])
      |> Enum.reject(&(is_nil(&1) or Map.has_key?(known, &1)))
      |> Enum.uniq()

    case missing do
      [] ->
        known

      ids ->
        Map.merge(
          known,
          Map.new(Repo.all(from(f in Entry, where: f.id in ^ids, select: {f.id, f.seq})))
        )
    end
  end

  ## External form

  @doc """
  The external form of a feedback record (MCP, web, notifications). Needs
  `load/2`.
  """
  @spec view(Entry.t()) :: view()
  def view(%Entry{task_ident: ident} = entry) when is_binary(ident) do
    %{
      id: Id.build(ident, entry.seq),
      seq: entry.seq,
      thread_seq: entry.thread_seq,
      reply_to: entry.reply_to_seq && Id.build(ident, entry.reply_to_seq),
      reply_root: entry.reply_root_seq && Id.build(ident, entry.reply_root_seq),
      target: entry.target,
      kind: Atom.to_string(entry.kind),
      content: entry.content,
      author: actor_ref(entry.author),
      mentions: entry.mention_names,
      status: Atom.to_string(entry.status),
      supersedes: entry.supersedes_seq && Id.build(ident, entry.supersedes_seq),
      superseded_by: entry.superseded_by_seq && Id.build(ident, entry.superseded_by_seq),
      dispatch: entry.dispatch_view,
      steer: entry.steer,
      at: entry.inserted_at
    }
  end

  defp actor_ref(%Actor{name: name, kind: kind}), do: %{name: name, kind: Atom.to_string(kind)}

  ## Notifications

  defp notify_entry(task, entry),
    do: Events.after_commit(Events.topic(:task, task.id), {:feedback_added, view(entry)})

  defp notify_task(task),
    do:
      Events.after_commit(
        Events.topic(:project, task.project_id),
        {:task_updated, Tasks.summary(Tasks.load_summary(task))}
      )
end
