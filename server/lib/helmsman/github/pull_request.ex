defmodule Helmsman.GitHub.PullRequest do
  @moduledoc """
  A pull request of a task (`add-pr-reconcile-merge` decision 2). A task
  may have several: a new one is opened when a merged task gets new
  pushes, or after its project was bound to another repository. The
  task's current pull request is its newest row (`id`) in the repository
  its project is bound to now (decision 20); rows of other repositories
  are history and no longer managed.

  Only the reconciliation (`Helmsman.GitHub.PullRequests.Reconcile`)
  writes the GitHub facts (`state`, `head_sha`, checks, merge result);
  people's requests write `merge_request` and `waiting_since`.

  `merge_reason` is a machine-readable code (`merge_reasons/0`), set when
  `merge_status` is `waiting`, `stale`, `blocked` or `failed`;
  `merge_note` explains it in English. `checks` (decision 22) is
  `%{"head_sha", "total", "passed", "pending", "failed" => [name]}` for the
  head it was read for.
  """

  use Ecto.Schema

  alias Helmsman.GitHub.Repository
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Workspace

  @type t :: %__MODULE__{}

  @states [:draft, :open, :merged, :closed]
  @checks_states [:none, :pending, :success, :failure]
  @merge_statuses [:none, :waiting, :stale, :merged, :blocked, :failed]
  @merge_reasons ~w(policy_manual agent_verified not_independent verified_sha_missing
                    verified_sha_not_pushed push_chain_broken run_active head_changed
                    ci_pending ci_timeout required_checks merge_rejected pr_closed
                    repository_unavailable branch_missing ci_failed_limit
                    merge_conflict_limit)a

  schema "task_pull_requests" do
    belongs_to :workspace, Workspace
    belongs_to :task, Task
    belongs_to :repository, Repository
    field :number, :integer
    field :node_id, :string
    field :url, :string
    field :branch, :string
    field :base_branch, :string
    field :state, Ecto.Enum, values: @states
    field :head_sha, :string
    field :checks_state, Ecto.Enum, values: @checks_states, default: :none
    field :checks, :map
    field :merge_status, Ecto.Enum, values: @merge_statuses, default: :none
    field :merge_reason, Ecto.Enum, values: @merge_reasons
    field :merge_note, :string
    field :merged_sha, :string
    field :merged_at, :utc_datetime_usec
    field :included_sha, :string
    field :closed_by_helmsman, :boolean, default: false
    field :draft_supported, :boolean, default: true
    field :auto_reopen_count, :integer, default: 0
    field :waiting_since, :utc_datetime_usec
    field :merge_request, :map
    field :escalated_event_id, :integer
    field :branch_deleted_at, :utc_datetime_usec
    field :rescue_cleaned_at, :utc_datetime_usec
    field :reconciled_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every merge reason code."
  @spec merge_reasons() :: [atom()]
  def merge_reasons, do: @merge_reasons

  @doc "Whether the pull request is open (draft or ready for review)."
  @spec open?(t() | nil) :: boolean()
  def open?(%__MODULE__{state: state}), do: state in [:draft, :open]
  def open?(nil), do: false
end
