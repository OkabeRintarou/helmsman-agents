defmodule Helmsman.Backup.SpecState do
  @moduledoc "Replays portable audit records without database or run references."
  alias Helmsman.Backup.Format
  alias Helmsman.TaskSpecs.State

  def replay(events, notes) do
    State.replay(
      Enum.map(events, fn e ->
        %{
          number: e["n"],
          action: e["action"],
          version: e["version"],
          data: e["data"],
          actor_id: e["actor"],
          source_run_id: nil,
          inserted_at: parse(e["at"])
        }
      end),
      Enum.map(notes, fn n ->
        %{
          review: n["review"],
          issue: n["issue"],
          number: n["n"],
          resolution: atom(n["resolution"])
        }
      end)
    )
  end

  def portable(state) do
    proposal = state.proposal

    %{
      "change_id" => state.change_id,
      "status" => to_string(state.status),
      "latest_version" => state.latest_version,
      "final_version" => state.final_version,
      "proposal" =>
        if(proposal,
          do: %{
            "version" => proposal.version,
            "summary" => proposal.summary,
            "by" => proposal.by_id,
            "at" => Format.time(proposal.at)
          }
        )
    }
  end

  def parse(nil), do: nil
  def parse(time), do: elem(DateTime.from_iso8601(time), 1)
  def atom(nil), do: nil
  def atom(value), do: String.to_existing_atom(value)
end
