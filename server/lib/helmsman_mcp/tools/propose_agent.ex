defmodule HelmsmanMCP.Tools.ProposeAgent do
  @moduledoc """
  `propose_agent`: adds or changes one agent of the draft
  (`add-agent-conversation` decision 7). Listed only for design runs.
  `:read` mode: it writes the conversation's draft, never as an identity
  of the session, so the pipeline resolves no writer.
  """

  use HelmsmanMCP.Tool,
    name: "propose_agent",
    description:
      "Add an agent to the draft, or change one (by name, case-insensitive). A new agent " <>
        "needs name, provider and instructions; a change keeps every field you leave out, and " <>
        "null restores a field's default. Checked like creating the agent for the user: a " <>
        "failure lists each field to fix and leaves the draft unchanged. This never creates " <>
        "the agent: the user confirms the draft in the web UI. Only in agent design runs.",
    schema: %{
      name:
        {:required, :string,
         description: "Agent name: a-z, 0-9, '.', '_', '/', '-' (e.g. fe-dev or web/dev)."},
      previous_name: {:string, description: "To rename a draft agent: its current name."},
      provider: {:string, description: "The CLI: claude, codex, copilot, cursor, ..."},
      instructions:
        {:string,
         description:
           "Who the agent is, how it works and what it delivers (English unless the user " <>
             "asks otherwise; at most 64 KB)."},
      # The fields with a default take null to restore it (decision 7):
      # nullable in the advertised schema too.
      description:
        {:meta, {:either, {:string, nil}},
         [description: "One line for people (at most 1000 characters); null: empty."]},
      runtime_id:
        {:meta, {:either, {:integer, nil}},
         [description: "A runtime ID from get_design (the user's machine); null: none."]},
      provider_account_id:
        {:meta, {:either, {:integer, nil}},
         [description: "A provider account ID from get_design (same CLI); null: none."]},
      model:
        {:meta, {:either, {:string, nil}},
         [
           description:
             "Model, from the runtime's list unless an account is bound; null: the CLI default."
         ]},
      effort:
        {:meta, {:either, {:string, nil}},
         [description: "Reasoning effort, from the runtime's list; null: the CLI default."]},
      capabilities:
        {:meta, {:either, {{:list, :string}, nil}},
         [description: "[] or [\"create_tasks\"]; null: []."]},
      access:
        {:meta, {:either, {:string, nil}},
         [description: "owner_only (default) or workspace; null: owner_only."]},
      max_concurrency:
        {:meta, {:either, {:integer, nil}}, [description: "1-16; null: the default 2."]},
      timeout_minutes:
        {:meta, {:either, {:integer, nil}}, [description: "1-1200; null: the default 120."]},
      idle_timeout_minutes:
        {:meta, {:either, {:integer, nil}}, [description: "1-240; null: the default 20."]}
    },
    mode: :read

  alias Helmsman.AgentDesigns

  @impl HelmsmanMCP.Tool
  def call(args, %{scope: scope}), do: AgentDesigns.propose_agent(scope, args)
end
