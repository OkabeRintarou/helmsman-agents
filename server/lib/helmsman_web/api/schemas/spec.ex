defmodule HelmsmanWeb.API.Schemas.SpecParts do
  @moduledoc false
  # Pieces of the spec schemas (`add-spec-workflow` decision 21).

  alias OpenApiSpex.Schema

  def int, do: %Schema{type: :integer}
  def bool, do: %Schema{type: :boolean}
  def str, do: %Schema{type: :string}
  def nstr, do: %Schema{type: :string, nullable: true}
  def nint, do: %Schema{type: :integer, nullable: true}
  def time, do: %Schema{type: :string, format: :"date-time"}
  def ntime, do: %Schema{type: :string, format: :"date-time", nullable: true}

  def obj(properties, required \\ []),
    do: %Schema{type: :object, properties: properties, required: required}

  def list(items), do: %Schema{type: :array, items: items}

  def dispatch do
    %Schema{
      type: :object,
      nullable: true,
      description: "The managed agent run the write started, merged into or skipped.",
      properties: %{
        target: str(),
        squad: nstr(),
        result: %Schema{type: :string, enum: ~w(queued merged deferred skipped)},
        reason: nstr(),
        run_id: nint()
      }
    }
  end

  def validation do
    obj(
      %{
        valid: bool(),
        errors:
          list(obj(%{file: str(), line: nint(), rule: str(), message: str()}, [:file, :rule]))
      },
      [:valid, :errors]
    )
  end

  def file_list, do: list(obj(%{path: str(), bytes: int()}, [:path, :bytes]))

  def statuses, do: ~w(draft in_review pending_approval finalized abandoned)
end

defmodule HelmsmanWeb.API.Schemas.Spec do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "Spec",
      description: "A task's spec: an OpenSpec change kept in Helmsman.",
      type: :object,
      properties: %{
        task: str(),
        change_id: str(),
        status: %Schema{type: :string, enum: statuses()},
        latest_version: int(),
        final_version: nint(),
        finalize_mode: %Schema{type: :string, enum: ~w(approval leader)},
        proposal: %Schema{
          type: :object,
          nullable: true,
          properties: %{version: int(), summary: nstr(), by: nstr(), at: time()}
        },
        pending_reviews:
          list(obj(%{n: int(), reviewer: str(), version: int(), requested_by: str(), at: time()})),
        unresolved: obj(%{p1: int(), p2: int(), p3: int()}),
        latest_valid: %Schema{type: :boolean, nullable: true},
        lock_version: int()
      },
      required: [:task, :change_id, :status, :latest_version, :finalize_mode]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecBrief do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SpecBrief",
      description: "The task's spec in a task view (null without one).",
      type: :object,
      nullable: true,
      properties: %{
        change_id: str(),
        status: %Schema{type: :string, enum: statuses()},
        latest_version: int(),
        final_version: nint(),
        finalize_mode: str(),
        unresolved_issues: int(),
        pending_reviews: int()
      }
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecDetail do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts
  alias HelmsmanWeb.API.Schemas
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SpecDetail",
      description:
        "The spec, its versions and one version with its validation and files (content only " <>
          "for the requested paths; above 256 KB without files, only the list and truncated).",
      type: :object,
      properties: %{
        spec: Schemas.Spec,
        versions:
          list(
            obj(%{
              number: int(),
              author: str(),
              at: time(),
              note: str(),
              valid: bool(),
              finalized: list(obj(%{at: time(), by: str()}))
            })
          ),
        version: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            number: int(),
            validation: validation(),
            files: list(obj(%{path: str(), bytes: int(), content: str()}, [:path, :bytes])),
            truncated: str()
          }
        }
      },
      required: [:spec, :versions, :version]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecDiff do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SpecDiff",
      description: "Two versions compared file by file; diff is unified diff text.",
      type: :object,
      properties: %{
        from: int(),
        to: nint(),
        truncated: bool(),
        files:
          list(
            obj(
              %{
                path: str(),
                change: %Schema{
                  type: :string,
                  enum: ~w(added removed modified replaced unchanged)
                },
                old_lines: int(),
                new_lines: int(),
                diff: str()
              },
              [:path, :change]
            )
          )
      },
      required: [:from, :files, :truncated]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecReviews do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts

  @note obj(%{
          n: int(),
          author: str(),
          kind: str(),
          resolution: nstr(),
          fixed_in_version: nint(),
          body: nstr(),
          at: time()
        })

  @issue obj(%{
           ref: str(),
           severity: str(),
           file: nstr(),
           line: nint(),
           anchor: nstr(),
           body: str(),
           suggestion: nstr(),
           resolution: str(),
           notes: list(@note)
         })

  OpenApiSpex.schema(
    %{
      title: "SpecReviews",
      description: "The review requests and the reviews with their issues and discussion.",
      type: :object,
      properties: %{
        requests:
          list(
            obj(%{
              n: int(),
              version: int(),
              reviewer: str(),
              requested_by: str(),
              note: nstr(),
              status: str(),
              close_reason: nstr(),
              review: nint(),
              at: time(),
              closed_at: ntime()
            })
          ),
        reviews:
          list(
            obj(%{
              number: int(),
              version: int(),
              reviewer: str(),
              verdict: str(),
              summary: str(),
              at: time(),
              issues: list(@issue)
            })
          )
      },
      required: [:requests, :reviews]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecEvents do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts

  OpenApiSpex.schema(
    %{
      title: "SpecEvents",
      description: "The spec's audit events, oldest first.",
      type: :array,
      items:
        obj(
          %{
            n: int(),
            actor: str(),
            action: str(),
            version: nint(),
            data: %OpenApiSpex.Schema{type: :object},
            at: time()
          },
          [:n, :action, :at]
        )
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecVersionResult do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts

  OpenApiSpex.schema(
    %{
      title: "SpecVersionResult",
      description:
        "A submitted (or, with dry_run, checked) version: its number (null for a dry run), " <>
          "files and validation. An import adds warnings (ignored paths); an import dry run " <>
          "also base_version, change_id and diff.",
      type: :object,
      properties: %{
        version: nint(),
        files: file_list(),
        validation: validation(),
        hint: str(),
        warnings: list(str()),
        dry_run: bool(),
        base_version: int(),
        change_id: nstr(),
        diff: HelmsmanWeb.API.Schemas.SpecDiff
      },
      required: [:version, :files, :validation]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecReviewResult do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts

  OpenApiSpex.schema(
    %{
      title: "SpecReviewResult",
      description: "The review's number, its issue IDs and the coordinator woken, if any.",
      type: :object,
      properties: %{review: int(), issues: list(str()), dispatch: dispatch()},
      required: [:review, :issues]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecNoteResult do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts

  OpenApiSpex.schema(
    %{
      title: "SpecNoteResult",
      description: "The issue, its resolution after the note and the note's number.",
      type: :object,
      properties: %{ref: str(), resolution: str(), note: int()},
      required: [:ref, :resolution, :note]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecDecision do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SpecDecision",
      description:
        "The spec after finalize (status and decision: approved, finalized or proposed) or " <>
          "reject, and the assignee woken, if any.",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: statuses()},
        decision: %Schema{type: :string, enum: ~w(approved finalized proposed)},
        spec: HelmsmanWeb.API.Schemas.Spec,
        dispatch: dispatch()
      },
      required: [:spec]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecRequests do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts

  OpenApiSpex.schema(
    %{
      title: "SpecRequests",
      description:
        "Each reviewer's request (existing: it was already pending) and the review run started.",
      type: :object,
      properties: %{
        requests:
          list(
            obj(
              %{reviewer: str(), request: int(), existing: bool(), dispatch: dispatch()},
              [:reviewer, :request, :existing]
            )
          )
      },
      required: [:requests]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecCancelResult do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts

  OpenApiSpex.schema(
    %{
      title: "SpecCancelResult",
      description: "The withdrawn request and the spec after it.",
      type: :object,
      properties: %{request: int(), reviewer: str(), spec: HelmsmanWeb.API.Schemas.Spec},
      required: [:request, :reviewer, :spec]
    },
    struct?: false,
    derive?: false
  )
end

defmodule HelmsmanWeb.API.Schemas.SpecAttention do
  @moduledoc false
  require OpenApiSpex
  import HelmsmanWeb.API.Schemas.SpecParts

  @item obj(%{
          task: str(),
          title: str(),
          version: int(),
          proposed_by: str(),
          requested_by: str(),
          at: time()
        })

  OpenApiSpex.schema(
    %{
      title: "SpecAttention",
      description:
        "Specs waiting for you: proposals to approve (members and above) and review " <>
          "requests for your human identity (at most 50 each).",
      type: :object,
      properties: %{pending_approval: list(@item), review_requests: list(@item)},
      required: [:pending_approval, :review_requests]
    },
    struct?: false,
    derive?: false
  )
end
