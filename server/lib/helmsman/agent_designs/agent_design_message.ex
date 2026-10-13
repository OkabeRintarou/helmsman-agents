defmodule Helmsman.AgentDesigns.AgentDesignMessage do
  @moduledoc """
  A message of a creation conversation (`add-agent-conversation` decision
  3), numbered by `seq` within it:

    * `user`: `content`, `edits` (the user's draft changes not yet told
      to the helper when it was sent, decision 16) and `run_id`, the design
      run it started;
    * `assistant`: `content`, the helper's reply (the run's last output);
    * `system`: `code` (`stopped`, `queue_timeout`, `failed` with the
      failure reason in `detail`, `cancelled`, `no_reply`,
      `helper_changed` with the new helper's name in `detail`).

  At most one non-`user` message per run (the settlement is idempotent).
  """

  use Ecto.Schema

  alias Helmsman.AgentDesigns.AgentDesign
  alias Helmsman.Runs.Run

  @type role :: :user | :assistant | :system
  @type t :: %__MODULE__{}

  @codes ~w(stopped queue_timeout failed cancelled no_reply helper_changed)

  schema "agent_design_messages" do
    belongs_to :design, AgentDesign
    field :seq, :integer
    field :role, Ecto.Enum, values: [:user, :assistant, :system]
    field :content, :string
    field :edits, {:array, :map}
    field :code, :string
    field :detail, :string
    belongs_to :run, Run
    field :inserted_at, :utc_datetime_usec
  end

  @doc "The codes of system messages."
  @spec codes() :: [String.t()]
  def codes, do: @codes
end
