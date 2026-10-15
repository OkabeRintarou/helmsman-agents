defmodule HelmsmanMCP.Tools.ReplySpecIssue do
  @moduledoc "`reply_spec_issue`: answers or discusses an issue of a spec review."

  use HelmsmanMCP.Tool,
    name: "reply_spec_issue",
    description:
      "Reply to a spec review issue (e.g. R2.3): resolution accepted (you fix it), disputed " <>
        "(you disagree; give the reason in body) or withdrawn (by its reviewer); without " <>
        "resolution the reply is a comment that changes nothing.",
    schema: %{
      task_id: {:required, :string, description: "Task ID (e.g. BOS-12)."},
      issue: {:required, :string, description: "The issue (e.g. R2.3)."},
      body: {:required, :string, description: "The reply (Markdown, at most 8 KB)."},
      resolution: {:string, description: "accepted, disputed or withdrawn."},
      fixed_in_version:
        {:integer, description: "With accepted: the version that fixes it, if submitted."}
    },
    mode: :write

  alias Helmsman.TaskSpecs
  alias HelmsmanMCP.Args

  @resolutions [nil, "accepted", "disputed", "withdrawn"]

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id, "issue" => issue} = args, %{scope: scope}) do
    if args["resolution"] in @resolutions do
      TaskSpecs.add_note(
        scope,
        id,
        issue,
        Args.take(args, [:body, :resolution, :fixed_in_version])
      )
    else
      {:error,
       {:spec, :invalid_params,
        %{
          field: :resolution,
          message: "must be accepted, disputed or withdrawn (rulings use rule_spec_issue)"
        }}}
    end
  end
end
