defmodule Helmsman.Runs.RunSteer do
  @moduledoc """
  A feedback record pushed into a running run (`add-run-steering`
  decision 2): one row per `(run_id, feedback_id)`, inserted when the push
  is decided (`sent_at`), `acked_at` set once by the daemon's receipt.
  """

  use Ecto.Schema

  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.Run
  alias Helmsman.Workspaces.Workspace

  @type t :: %__MODULE__{}

  @primary_key false
  schema "run_steers" do
    belongs_to :workspace, Workspace
    belongs_to :run, Run, primary_key: true
    belongs_to :feedback, Entry, primary_key: true
    field :sent_at, :utc_datetime_usec
    field :acked_at, :utc_datetime_usec
  end
end
