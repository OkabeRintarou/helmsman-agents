defmodule Helmsman.Feedback.Entry do
  @moduledoc """
  One feedback record of a task (designs/06): its number `seq` in the task
  (external ID `<task ID>#<seq>`), its place in the timeline `thread_seq`
  (a revision keeps the place of the record it revises), its author, kind,
  Markdown content and the identities it mentions.

  Rows are only ever inserted, except for the one update a revision makes
  to the record it supersedes (`status`, `superseded_by_id` and `search`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Helmsman.Actors.Actor
  alias Helmsman.Search.Document
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Workspace

  @type kind :: :comment | :review | :question | :answer
  @type status :: :active | :superseded
  @type t :: %__MODULE__{}

  @kinds [:comment, :review, :question, :answer]
  @statuses [:active, :superseded]
  @max_content_bytes 65_536

  schema "feedback" do
    belongs_to :workspace, Workspace
    belongs_to :task, Task
    field :seq, :integer
    field :thread_seq, :integer
    belongs_to :author, Actor
    field :kind, Ecto.Enum, values: @kinds, default: :comment
    field :content, :string
    field :mentions, {:array, :integer}, default: []
    field :status, Ecto.Enum, values: @statuses, default: :active
    belongs_to :supersedes, __MODULE__
    belongs_to :superseded_by, __MODULE__
    # The run the record was written in (an `hmr_` token), if any.
    belongs_to :source_run, Helmsman.Runs.Run
    # Written by the system from a run's last output (designs/13 §7).
    field :fallback, :boolean, default: false
    # The triggers the record caused (`add-continuation-triggers` decision
    # 10): `%{"agent_id", "trigger", "result", "reason", "run_id"}` each,
    # written in the transaction that inserts the record, never changed.
    field :dispatch, {:array, :map}, default: []
    # `Helmsman.Search.Document.feedback/1` of the content while active,
    # NULL once superseded (`add-fulltext-search` decision 5); never read
    # with the record.
    field :search, Helmsman.Search.TsVector, load_in_query: false

    # Filled in by `Helmsman.Feedback.load/2` for the external form.
    field :task_ident, :string, virtual: true
    field :mention_names, {:array, :string}, virtual: true, default: []
    field :supersedes_seq, :integer, virtual: true
    field :superseded_by_seq, :integer, virtual: true
    field :dispatch_view, {:array, :map}, virtual: true, default: []

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "All kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  A new record with `fields` and the search column of its content: every
  insert goes through here, so no record is written without it
  (`add-fulltext-search` decision 5).
  """
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields) do
    entry = struct!(__MODULE__, fields)
    %{entry | search: Document.feedback(entry.content)}
  end

  @doc """
  Validates the caller-supplied fields `kind` and `content` (keys may be
  atoms or strings). The content is kept as written (leading spaces matter
  in Markdown) but must not be blank, and is at most 64 KB. A missing
  `kind` keeps the entry's current one.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    # Blank strings are cast to nil (missing); others are kept untrimmed.
    |> cast(attrs, [:kind, :content])
    |> validate_required([:content])
    |> validate_length(:content, max: @max_content_bytes, count: :bytes)
    |> check_constraint(:content, name: :feedback_content_size, message: "must be at most 64 KB")
    |> check_constraint(:kind, name: :feedback_kind_check, message: "is invalid")
    |> unique_constraint(:seq, name: :feedback_task_id_seq_index)
    |> unique_constraint(:supersedes_id, name: :feedback_supersedes_id_index)
  end
end
