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
  alias Helmsman.Events
  alias Helmsman.Feedback.{Entry, Id, Mentions}
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  @type input :: %{kind: Entry.kind() | nil, content: String.t()}
  @type actor_ref :: %{name: String.t(), kind: String.t()}
  @type view :: %{
          id: String.t(),
          seq: pos_integer(),
          thread_seq: pos_integer(),
          kind: String.t(),
          content: String.t(),
          author: actor_ref() | nil,
          mentions: [String.t()],
          status: String.t(),
          supersedes: String.t() | nil,
          superseded_by: String.t() | nil,
          at: DateTime.t()
        }

  ## Adding

  @doc """
  Adds feedback to the task `ident` as `scope.actor` (`:add_feedback`).

  `attrs`: `kind` (`comment`, the default, `review`, `question` or
  `answer`) and `content` (Markdown, not blank, at most 64 KB; checked
  before the transaction, so invalid input takes no lock and no number).
  Returns the new entry (`load/2` done).
  """
  @spec add(Scope.t(), String.t(), map()) ::
          {:ok, Entry.t()} | {:error, Changeset.t() | :forbidden | :not_found | :no_actor}
  def add(%Scope{actor: nil}, _ident, _attrs), do: {:error, :no_actor}

  def add(%Scope{workspace: %Workspace{}} = scope, ident, attrs)
      when is_binary(ident) and is_map(attrs) do
    with {:ok, input} <- normalize(attrs),
         {:ok, ident, _key, _seq} <- Ident.parse(ident) do
      Workspaces.write_transaction(scope, :add_feedback, &add_locked(&1, ident, input))
    end
  end

  defp add_locked(scope, ident, input) do
    with {:ok, task} <- lock_task(scope.workspace.id, ident),
         {:ok, {entry, task}} <- insert_locked(task, scope, input) do
      notify_task(task)
      {:ok, entry}
    end
  end

  @doc """
  Validates feedback input (`kind`, `content`; atom or string keys)
  without touching the database. `kind` is `nil` when not given.
  """
  @spec normalize(map()) :: {:ok, input()} | {:error, Changeset.t()}
  def normalize(attrs) when is_map(attrs) do
    changeset = Entry.changeset(%Entry{kind: nil}, attrs)

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
  the caller has authorized its own action. Registers the
  `{:feedback_added, view}` notification on the task topic only; the
  caller notifies the project topic.

  Returns the new entry and the updated task.
  """
  @spec insert_locked(Task.t(), Scope.t(), input()) :: {:ok, {Entry.t(), Task.t()}}
  def insert_locked(%Task{} = task, %Scope{actor: %Actor{} = actor}, %{content: content} = input) do
    seq = task.feedback_seq + 1

    entry =
      Repo.insert!(%Entry{
        workspace_id: task.workspace_id,
        task_id: task.id,
        seq: seq,
        thread_seq: seq,
        author_id: actor.id,
        kind: input[:kind] || :comment,
        content: content,
        mentions: resolve_mentions(task.workspace_id, content)
      })

    task = refresh_counters(task, seq)
    entry = entry |> load(task.ident) |> hd()
    notify_entry(task, entry)
    {:ok, {entry, task}}
  end

  ## Revising

  @doc """
  Revises the feedback `id` (`KEY-N#S`) with new `content` and, optionally,
  a new `kind` (`:revise_feedback`, which checks the author rule).

  Appends a record by `scope.actor` in the place of the old one, which
  becomes superseded and points to it. Returns the new entry.

  Errors: a changeset for invalid input, `:not_found`, `:forbidden`,
  `:no_actor` and `{:superseded, latest_id}` when the record was already
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

  # Lock order: the task row, then the record.
  defp revise_locked(scope, ident, seq, input) do
    with {:ok, task} <- lock_task(scope.workspace.id, ident),
         {:ok, old} <- lock_entry(task, seq),
         :ok <- check_active(task, old) do
      {entry, task} = insert_revision(task, old, scope, input)
      notify_task(task)
      {:ok, entry}
    end
  end

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

  defp insert_revision(task, old, scope, input) do
    seq = task.feedback_seq + 1

    entry =
      Repo.insert!(%Entry{
        workspace_id: task.workspace_id,
        task_id: task.id,
        seq: seq,
        thread_seq: old.thread_seq,
        author_id: scope.actor.id,
        kind: input.kind || old.kind,
        content: input.content,
        mentions: resolve_mentions(task.workspace_id, input.content),
        supersedes_id: old.id
      })

    {1, _} =
      Repo.update_all(where(Entry, id: ^old.id),
        set: [status: :superseded, superseded_by_id: entry.id]
      )

    task = refresh_counters(task, seq)
    entry = entry |> load(task.ident) |> hd()
    notify_entry(task, entry)
    {entry, task}
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
  author, the mentioned names and the numbers of the linked records. At
  most three queries, whatever the number of entries.
  """
  @spec load([Entry.t()] | Entry.t(), String.t()) :: [Entry.t()]
  def load(%Entry{} = entry, ident), do: load([entry], ident)
  def load([], _ident), do: []

  def load(entries, ident) when is_list(entries) do
    entries = Repo.preload(entries, :author)

    names =
      case entries |> Enum.flat_map(& &1.mentions) |> Enum.uniq() do
        [] -> %{}
        ids -> Map.new(Repo.all(from(a in Actor, where: a.id in ^ids, select: {a.id, a.name})))
      end

    seqs = linked_seqs(entries)

    Enum.map(entries, fn entry ->
      %{
        entry
        | task_ident: ident,
          mention_names: entry.mentions |> Enum.map(&names[&1]) |> Enum.reject(&is_nil/1),
          supersedes_seq: seqs[entry.supersedes_id],
          superseded_by_seq: seqs[entry.superseded_by_id]
      }
    end)
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
      kind: Atom.to_string(entry.kind),
      content: entry.content,
      author: actor_ref(entry.author),
      mentions: entry.mention_names,
      status: Atom.to_string(entry.status),
      supersedes: entry.supersedes_seq && Id.build(ident, entry.supersedes_seq),
      superseded_by: entry.superseded_by_seq && Id.build(ident, entry.superseded_by_seq),
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
