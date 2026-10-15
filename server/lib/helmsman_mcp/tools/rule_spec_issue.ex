defmodule HelmsmanMCP.Tools.RuleSpecIssue do
  @moduledoc "`rule_spec_issue`: the coordinator's ruling on a spec review issue."

  use HelmsmanMCP.Tool,
    name: "rule_spec_issue",
    description:
      "Rule on a spec review issue as its coordinator (a person, or the squad leader in its " <>
        "run as the squad): upheld (it must be fixed) or dismissed (it need not be), with " <>
        "the reason.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      issue: {:required, :string, description: "The issue (e.g. R2.3)."},
      ruling: {:required, :string, description: "upheld or dismissed."},
      reason: {:required, :string, description: "Why (at most 8 KB)."}
    },
    mode: :write

  alias Helmsman.TaskSpecs

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id, "issue" => issue, "ruling" => ruling} = args, %{scope: scope})
      when ruling in ["upheld", "dismissed"] do
    TaskSpecs.add_note(scope, id, issue, %{resolution: ruling, body: args["reason"]})
  end

  def call(_args, _ctx),
    do:
      {:error,
       {:spec, :invalid_params, %{field: :ruling, message: "must be upheld or dismissed"}}}
end
