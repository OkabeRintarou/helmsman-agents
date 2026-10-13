defmodule Helmsman.Tasks.Task do
  @moduledoc """
  A task (designs/04 §2): one piece of work in a project, identified for
  ever by `ident` (`KEY-N`).

  `status` only changes through the state machine; field edits never touch
  it. `lock_version` grows by one with every edit that changes something.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Helmsman.Actors.Actor
  alias Helmsman.Projects.Project
  alias Helmsman.Tasks.TaskEvent
  alias Helmsman.Workspaces.Workspace

  @type status :: :new | :in_progress | :done | :verified | :rejected | :cancelled
  @type kind :: :task | :epic
  @type priority :: :low | :medium | :high
  @type t :: %__MODULE__{}

  @statuses [:new, :in_progress, :done, :verified, :rejected, :cancelled]
  @priorities [:low, :medium, :high]
  @kinds [:task, :epic]
  @max_description_bytes 65_536
  @max_labels 20
  @max_label_length 32

  schema "tasks" do
    belongs_to :workspace, Workspace
    belongs_to :project, Project
    field :seq, :integer
    field :ident, :string
    field :title, :string
    field :description, :string, default: ""
    field :status, Ecto.Enum, values: @statuses, default: :new
    field :priority, Ecto.Enum, values: @priorities, default: :medium
    field :labels, {:array, :string}, default: []
    belongs_to :created_by, Actor
    belongs_to :assignee, Actor
    field :lock_version, :integer, default: 1
    # Set at creation, never changed. A task (never an epic) may belong to
    # an epic of its workspace, in any project (designs/04 §3).
    field :kind, Ecto.Enum, values: @kinds, default: :task
    belongs_to :epic, __MODULE__
    # Kept by `Helmsman.Feedback` under the task row lock: the last feedback
    # number given out, the active records and whether a question waits
    # for an answer.
    field :feedback_seq, :integer, default: 0
    field :feedback_count, :integer, default: 0
    field :open_question, :boolean, default: false
    # Written by `Helmsman.Tasks` with the fields it indexes
    # (`Helmsman.Search.Document.task/1`); never read with the task.
    field :search, Helmsman.Search.TsVector, load_in_query: false

    # Every commit in the task's history (first occurrence first), filled in
    # by `Helmsman.Tasks` when it loads tasks for their summary.
    field :commits, {:array, :string}, virtual: true, default: []
    # Every feedback record by number, filled in by `Helmsman.Tasks` for
    # the task detail.
    field :feedback, {:array, :any}, virtual: true, default: []
    # The dispatch outcomes (`Helmsman.Runs.Outcome`) of the `create/3` or
    # `update/4` call that returned the task.
    field :dispatch, {:array, :any}, virtual: true, default: []
    # Filled in by `Helmsman.Tasks` with `commits`: the ID of the epic the
    # task belongs to and, for an epic, its progress
    # (`Helmsman.Tasks.Epics.progress/2`).
    field :epic_ident, :string, virtual: true
    field :progress, :map, virtual: true
    # Filled in for the detail: an epic's steps (by ID) and a step's epic
    # title.
    field :children, {:array, :any}, virtual: true
    field :epic_title, :string, virtual: true
    # Whether an outgoing `depends_on` is unsatisfied (`Helmsman.Links`),
    # filled in by `Helmsman.Tasks` with the summary fields.
    field :blocked, :boolean, virtual: true, default: false
    # Every link of the task (`Helmsman.Links.for_task/1`), filled in for
    # the task detail.
    field :links, {:array, :any}, virtual: true, default: []

    has_many :events, TaskEvent

    timestamps(type: :utc_datetime_usec)
  end

  @doc "All statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "All kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "All priorities."
  @spec priorities() :: [priority()]
  def priorities, do: @priorities

  @doc """
  Changeset for the editable fields: title, description, priority and
  labels. Anything else in `attrs` (status, ident, ...) is ignored; the
  caller sets the other columns.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :priority, :labels], empty_values: [])
    |> update_change(:title, &normalize_title/1)
    |> update_change(:description, &normalize_description/1)
    |> update_change(:labels, &normalize_labels/1)
    |> validate_required([:title, :priority])
    |> validate_length(:title, min: 1, max: 200, count: :codepoints)
    |> validate_length(:description, max: @max_description_bytes, count: :bytes)
    |> validate_labels()
    |> check_constraint(:title, name: :tasks_title_length, message: "must be 1-200 characters")
    |> check_constraint(:description,
      name: :tasks_description_size,
      message: "must be at most 64 KB"
    )
    |> check_constraint(:labels, name: :tasks_labels_count, message: "must be at most 20 labels")
    |> check_constraint(:priority, name: :tasks_priority_check, message: "is invalid")
    |> unique_constraint(:ident, name: :tasks_workspace_id_ident_index)
    |> unique_constraint(:seq, name: :tasks_project_id_seq_index)
    |> foreign_key_constraint(:assignee_id, name: :tasks_assignee_id_fkey)
    |> foreign_key_constraint(:epic, name: :tasks_epic_id_fkey, message: "not found")
    |> check_constraint(:kind, name: :tasks_kind_check, message: "is invalid")
    |> check_constraint(:epic,
      name: :tasks_epic_not_nested,
      message: "an epic cannot belong to another epic"
    )
    |> check_constraint(:epic, name: :tasks_epic_not_self, message: "is not an epic")
  end

  @doc """
  Normalizes labels: trimmed, downcased, blanks dropped, duplicates removed,
  input order kept.
  """
  @spec normalize_labels([String.t()] | nil) :: [String.t()]
  def normalize_labels(nil), do: []

  def normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_title(title) when is_binary(title), do: String.trim(title)
  defp normalize_title(title), do: title

  defp normalize_description(nil), do: ""
  defp normalize_description(description), do: description

  defp validate_labels(changeset) do
    changeset
    |> validate_length(:labels, max: @max_labels, message: "must be at most 20 labels")
    |> validate_change(:labels, fn :labels, labels ->
      if Enum.all?(labels, &(String.length(&1) <= @max_label_length)),
        do: [],
        else: [labels: "each label must be 1-32 characters"]
    end)
  end
end
