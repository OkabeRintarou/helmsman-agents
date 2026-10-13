defmodule HelmsmanWeb.API.Schemas do
  @moduledoc """
  The response schemas of the REST API (`add-rest-api` decision 8), by
  hand: the JSON the MCP tools return (`HelmsmanMCP.Present`) and the
  REST-only results. Every success response of the controller tests is
  checked against them (`OpenApiSpex.TestAssertions.assert_schema/3`).
  """
end

defmodule HelmsmanWeb.API.Schemas.Error do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "Error",
      description: "Every REST error: a stable code, an English message and details.",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "Stable error code (e.g. not_found)."},
        message: %Schema{type: :string, description: "English explanation; may change."},
        detail: %Schema{type: :object, description: "Details of the error; {} when none."}
      },
      required: [:error, :message, :detail]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.ActorRef do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "ActorRef",
      description: "An identity: a human, an agent, a squad or the system.",
      type: :object,
      nullable: true,
      properties: %{
        name: %Schema{type: :string},
        kind: %Schema{type: :string, enum: ["human", "agent", "squad", "system"]}
      },
      required: [:name, :kind]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.Project do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  import HelmsmanWeb.API.Schemas.Helpers, only: [nullable: 1, string: 0, string: 1, time: 0]

  OpenApiSpex.schema(
    %{
      title: "Project",
      type: :object,
      properties: %{
        key: string("Project key (e.g. BOS)."),
        name: string(),
        description: nullable(string()),
        archived: %Schema{type: :boolean},
        archived_at: nullable(time()),
        task_count: %Schema{type: :integer},
        created_at: time(),
        updated_at: time()
      },
      required: [:key, :name, :archived, :task_count, :created_at, :updated_at]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.ProjectList do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{title: "ProjectList", type: :array, items: HelmsmanWeb.API.Schemas.Project},
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.Progress do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "Progress",
      description: "An epic's steps by status.",
      type: :object,
      nullable: true,
      properties: %{
        total: %Schema{type: :integer},
        done: %Schema{type: :integer},
        by_status: %Schema{type: :object, additionalProperties: %Schema{type: :integer}}
      },
      required: [:total, :done, :by_status]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.Dispatch do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  import HelmsmanWeb.API.Schemas.Helpers, only: [nullable: 1, string: 0, strings: 0]

  OpenApiSpex.schema(
    %{
      title: "Dispatch",
      description: "What a write did to managed agents: one outcome per triggered agent.",
      type: :array,
      items: %Schema{
        type: :object,
        properties: %{
          agent: string(),
          trigger: string(),
          result: string(),
          reason: nullable(string()),
          blocked_by: strings(),
          squad: string(),
          refused: %Schema{type: :object}
        },
        required: [:agent, :trigger, :result]
      }
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.TaskSummary do
  @moduledoc false
  require OpenApiSpex
  alias HelmsmanWeb.API.Schemas.Helpers
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "TaskSummary",
      type: :object,
      properties: Helpers.summary_properties(),
      required: Helpers.summary_required()
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.TaskList do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{title: "TaskList", type: :array, items: HelmsmanWeb.API.Schemas.TaskSummary},
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.Feedback do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  import HelmsmanWeb.API.Schemas.Helpers,
    only: [nullable: 1, string: 0, string: 1, time: 0, strings: 0]

  OpenApiSpex.schema(
    %{
      title: "Feedback",
      type: :object,
      properties: %{
        id: string("Feedback ID (e.g. BOS-12#3)."),
        seq: %Schema{type: :integer},
        thread_seq: %Schema{type: :integer, nullable: true},
        kind: string(),
        content: string(),
        author: HelmsmanWeb.API.Schemas.ActorRef,
        mentions: strings(),
        status: string(),
        supersedes: nullable(string()),
        superseded_by: nullable(string()),
        at: time(),
        dispatch: HelmsmanWeb.API.Schemas.Dispatch
      },
      required: [:id, :seq, :kind, :content, :author, :status, :at]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.FeedbackList do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "FeedbackList",
      type: :object,
      properties: %{
        task_id: %Schema{type: :string},
        feedback: %Schema{type: :array, items: HelmsmanWeb.API.Schemas.Feedback}
      },
      required: [:task_id, :feedback]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.TaskDetail do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  import HelmsmanWeb.API.Schemas.Helpers, only: [nullable: 1, string: 0, time: 0, strings: 0]

  alias HelmsmanWeb.API.Schemas

  @history %Schema{
    type: :object,
    properties: %{
      from: nullable(string()),
      to: string(),
      actor: Schemas.ActorRef,
      comment: nullable(string()),
      commits: strings(),
      tests: %Schema{
        type: :object,
        nullable: true,
        properties: %{
          command: nullable(string()),
          passed: %Schema{type: :boolean},
          summary: nullable(string())
        }
      },
      auto: %Schema{type: :boolean},
      feedback: nullable(string()),
      at: time()
    },
    required: [:to, :at]
  }

  @link %Schema{
    type: :object,
    properties: %{
      type: %Schema{type: :string, enum: ["depends_on", "replaces"]},
      direction: %Schema{type: :string},
      task: string(),
      title: string(),
      status: string(),
      kind: string(),
      actor: Schemas.ActorRef,
      created_at: time(),
      waiting_for: %Schema{
        type: :string,
        description: "On an unsatisfied depends_on: what it waits for (e.g. status)."
      }
    },
    required: [:type, :direction, :task, :status]
  }

  OpenApiSpex.schema(
    %{
      title: "TaskDetail",
      description:
        "A task with its description, history, feedback, links and, for an epic, its steps. " <>
          "Writes add `dispatch` when they triggered managed agents.",
      type: :object,
      properties:
        Map.merge(Schemas.Helpers.summary_properties(), %{
          description: nullable(string()),
          history: %Schema{type: :array, items: @history},
          feedback: %Schema{type: :array, items: Schemas.Feedback},
          children: %Schema{type: :array, nullable: true, items: Schemas.TaskSummary},
          epic_title: nullable(string()),
          links: %Schema{type: :array, items: @link},
          dispatch: Schemas.Dispatch
        }),
      required: Schemas.Helpers.summary_required() ++ [:history, :feedback, :links]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SearchResult do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  import HelmsmanWeb.API.Schemas.Helpers, only: [string: 0]

  OpenApiSpex.schema(
    %{
      title: "SearchResult",
      description: "Tasks matching the query, best first; keys without a value are left out.",
      type: :array,
      items: %Schema{
        type: :object,
        properties: %{
          id: string(),
          title: string(),
          status: string(),
          project_key: string(),
          assignee: HelmsmanWeb.API.Schemas.ActorRef,
          snippet: string(),
          feedback: %Schema{
            type: :object,
            properties: %{
              id: string(),
              author: string(),
              kind: string(),
              snippet: string()
            }
          }
        },
        required: [:id, :title, :status, :project_key]
      }
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.ActorList do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  import HelmsmanWeb.API.Schemas.Helpers, only: [nullable: 1, string: 0, time: 0]

  OpenApiSpex.schema(
    %{
      title: "ActorList",
      description: "Every identity of the workspace.",
      type: :array,
      items: %Schema{
        type: :object,
        properties: %{
          name: string(),
          kind: %Schema{type: :string, enum: ["human", "agent", "squad", "system"]},
          owner: nullable(string()),
          disabled: %Schema{type: :boolean},
          project: nullable(string()),
          worktree: nullable(string()),
          last_seen_at: nullable(time())
        },
        required: [:name, :kind, :disabled]
      }
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.AgentList do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  import HelmsmanWeb.API.Schemas.Helpers, only: [nullable: 1, string: 0]

  OpenApiSpex.schema(
    %{
      title: "AgentList",
      description: "The agents and squads of the workspace.",
      type: :object,
      properties: %{
        agents: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              name: string(),
              kind: %Schema{type: :string, enum: ["managed", "external"]},
              owner: string(),
              provider: nullable(string()),
              description: nullable(string()),
              disabled: %Schema{type: :boolean},
              archived: %Schema{type: :boolean},
              busy: %Schema{type: :boolean},
              queued: %Schema{type: :integer},
              wake_on_requested: %Schema{type: :boolean}
            },
            required: [:name, :kind, :owner, :disabled, :archived, :busy, :queued]
          }
        },
        squads: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              name: string(),
              description: nullable(string()),
              leader: string(),
              members: %Schema{
                type: :array,
                items: %Schema{
                  type: :object,
                  properties: %{
                    name: string(),
                    kind: string(),
                    role_note: nullable(string())
                  },
                  required: [:name, :kind]
                }
              },
              disabled: %Schema{type: :boolean},
              busy: %Schema{type: :boolean}
            },
            required: [:name, :leader, :members, :disabled, :busy]
          }
        }
      },
      required: [:agents, :squads]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.Run do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  import HelmsmanWeb.API.Schemas.Helpers, only: [nullable: 1, string: 0, string: 1, time: 0]

  OpenApiSpex.schema(
    %{
      title: "Run",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        task: nullable(string("Task ID, or null for a run without a task.")),
        agent: string(),
        lane: nullable(string()),
        status: string("QUEUED, RUNNING, SUCCEEDED, FAILED, CANCELLED, ..."),
        triggers: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              kind: string(),
              by: HelmsmanWeb.API.Schemas.ActorRef,
              at: time(),
              instructions: nullable(string())
            },
            required: [:kind, :at]
          }
        },
        failure_reason: nullable(string()),
        priority: %Schema{type: :integer, nullable: true},
        squad: string(),
        error: nullable(string("The error text; only for members and above.")),
        created_at: time(),
        updated_at: time()
      },
      required: [:id, :agent, :status, :triggers, :created_at, :updated_at]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.RunResult do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "RunResult",
      type: :object,
      properties: %{
        run: HelmsmanWeb.API.Schemas.Run,
        merged: %Schema{
          type: :boolean,
          description: "Started by hand: whether the request joined a queued run."
        }
      },
      required: [:run]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.RunList do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "RunList",
      type: :object,
      properties: %{runs: %Schema{type: :array, items: HelmsmanWeb.API.Schemas.Run}},
      required: [:runs]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.RunEvent do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  import HelmsmanWeb.API.Schemas.Helpers, only: [string: 0, time: 0]

  OpenApiSpex.schema(
    %{
      title: "RunEvent",
      description: "One execution event of a run.",
      type: :object,
      properties: %{
        seq: %Schema{type: :integer},
        kind: string(),
        at: time(),
        data: %Schema{type: :object}
      },
      required: [:seq, :kind, :at, :data]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.RunEvents do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "RunEvents",
      type: :object,
      properties: %{
        events: %Schema{type: :array, items: HelmsmanWeb.API.Schemas.RunEvent},
        pruned: %Schema{type: :boolean, description: "The events were deleted."},
        last_seq: %Schema{type: :integer, description: "The run's last event number."}
      },
      required: [:events, :pruned, :last_seq]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.Me do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  import HelmsmanWeb.API.Schemas.Helpers, only: [nullable: 1, string: 0, time: 0, strings: 0]

  OpenApiSpex.schema(
    %{
      title: "Me",
      description: "Who the token acts as.",
      type: :object,
      properties: %{
        user: %Schema{type: :object, properties: %{name: string()}, required: [:name]},
        workspace: %Schema{
          type: :object,
          properties: %{slug: string(), name: string()},
          required: [:slug, :name]
        },
        role: %Schema{type: :string, enum: ["owner", "admin", "member", "viewer"]},
        actor: HelmsmanWeb.API.Schemas.ActorRef,
        actor_source: %Schema{type: :string, enum: ["header", "default", "human"]},
        token: %Schema{
          type: :object,
          properties: %{
            name: string(),
            prefix: string(),
            scopes: strings(),
            expires_at: nullable(time())
          },
          required: [:name, :prefix, :scopes]
        }
      },
      required: [:user, :workspace, :role, :actor, :actor_source, :token]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.QueryResult do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "QueryResult",
      description: "A page of a BQL query or saved filter.",
      type: :object,
      properties: %{
        tasks: %Schema{type: :array, items: HelmsmanWeb.API.Schemas.TaskSummary},
        total: %Schema{type: :integer, description: "Every matching task, not only this page."},
        order: %Schema{
          description: "\"relevance\", or the sort fields and directions.",
          oneOf: [
            %Schema{type: :string, enum: ["relevance"]},
            %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{field: %Schema{type: :string}, dir: %Schema{type: :string}},
                required: [:field, :dir]
              }
            }
          ]
        },
        text: %Schema{type: :string, description: "A one-line summary of the page."}
      },
      required: [:tasks, :total, :order, :text]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.Filter do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "Filter",
      description: "A saved BQL query.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        name: %Schema{type: :string},
        bql: %Schema{type: :string},
        shared: %Schema{type: :boolean, description: "Shared with the workspace."},
        owner: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :integer},
            name: %Schema{type: :string, nullable: true},
            left: %Schema{type: :boolean, description: "The owner left the workspace."}
          },
          required: [:id, :left]
        },
        lock_version: %Schema{type: :integer}
      },
      required: [:id, :name, :bql, :shared, :owner, :lock_version]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.FilterList do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(
    %{title: "FilterList", type: :array, items: HelmsmanWeb.API.Schemas.Filter},
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.Deleted do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "Deleted",
      type: :object,
      properties: %{deleted: %Schema{type: :boolean}},
      required: [:deleted]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.AutopilotRecord do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "AutopilotRecord",
      description: "A trigger of an autopilot, as its webhook answers.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        status: %Schema{
          type: :string,
          enum: ~w(pending skipped started succeeded failed cancelled)
        },
        reason: %Schema{type: :string, nullable: true, description: "e.g. overlap"}
      },
      required: [:id, :status, :reason]
    },
    struct?: false,
    derive?: false
  )
end
