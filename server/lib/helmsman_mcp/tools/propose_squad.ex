defmodule HelmsmanMCP.Tools.ProposeSquad do
  @moduledoc """
  `propose_squad`: changes the squad part of a squad conversation's draft
  (`add-squads` decision 12). Listed only for design runs of squad
  conversations. `:read` mode: it writes the conversation's draft, never
  as an identity of the session.
  """

  use HelmsmanMCP.Tool,
    name: "propose_squad",
    description:
      "Set the squad of the draft: its name, description, leader (a managed agent: a new " <>
        "draft agent or an existing one), instructions and members (draft agents, existing " <>
        "managed agents or people, each with a role_note). Fields you give replace the old " <>
        "ones, members as a whole; null restores a field's default. Returns the squad and " <>
        "how many people can trigger it. This never creates the squad: the user confirms " <>
        "the draft. Only in squad design runs.",
    schema: %{
      name:
        {:meta, {:either, {:string, nil}},
         [description: "The squad's name (like an agent name)."]},
      description:
        {:meta, {:either, {:string, nil}}, [description: "One line for people (at most 2 KB)."]},
      leader:
        {:meta, {:either, {:string, nil}},
         [description: "The leader: a managed agent of the draft or of the workspace."]},
      instructions:
        {:meta, {:either, {:string, nil}},
         [description: "How the squad works, for its leader (Markdown, at most 16 KB)."]},
      members:
        {:meta, {:either, {{:list, :map}, nil}},
         [
           description:
             "[{name, role_note}]: at most 16 people or managed agents, not the leader; " <>
               "role_note at most 2 KB."
         ]}
    },
    mode: :read

  alias Helmsman.AgentDesigns

  @impl HelmsmanMCP.Tool
  def call(args, %{scope: scope}), do: AgentDesigns.propose_squad(scope, args)
end
