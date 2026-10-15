defmodule Helmsman.Backup.Export.Specs do
  @moduledoc "Portable spec records; file contents stay bounded to one version per cursor row."
  import Ecto.Query
  alias Helmsman.Actors.Actor
  alias Helmsman.Tasks.Task
  alias Helmsman.TaskSpecs.{Event, Issue, IssueNote, Review, ReviewRequest, Spec, Version}

  def query("specs", wid) do
    from(s in Spec,
      join: t in Task,
      on: t.id == s.task_id,
      join: a in Actor,
      on: a.id == s.created_by_id,
      left_join: b in Actor,
      on: b.id == s.proposal_by_id,
      where: s.workspace_id == ^wid,
      order_by: t.ident,
      select: %{
        "task" => t.ident,
        "change_id" => s.change_id,
        "status" => s.status,
        "latest_version" => s.latest_version,
        "final_version" => s.final_version,
        "proposal" =>
          fragment(
            ~s|CASE WHEN ? IS NULL THEN NULL ELSE jsonb_build_object('version', ?, 'summary', ?, 'by', ?, 'at', to_char(? AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) END|,
            s.proposal_version,
            s.proposal_version,
            s.proposal_summary,
            b.name,
            s.proposed_at
          ),
        "created_by" => a.name,
        "created_at" => s.inserted_at
      }
    )
  end

  def query("spec_versions", wid) do
    from(v in Version,
      join: s in Spec,
      on: s.id == v.spec_id,
      join: t in Task,
      on: t.id == s.task_id,
      join: a in Actor,
      on: a.id == v.author_id,
      where: v.workspace_id == ^wid,
      order_by: [t.ident, v.number],
      select: %{
        "task" => t.ident,
        "n" => v.number,
        "author" => a.name,
        "at" => v.inserted_at,
        "note" => v.note,
        "files" =>
          fragment(
            "COALESCE((SELECT jsonb_agg(jsonb_build_object('path', f.path, 'content', b.content) ORDER BY f.path) FROM task_spec_files f JOIN task_spec_blobs b ON b.id=f.blob_id WHERE f.version_id=?), '[]'::jsonb)",
            v.id
          )
      }
    )
  end

  def query("spec_review_requests", wid) do
    from(r in ReviewRequest,
      join: s in Spec,
      on: s.id == r.spec_id,
      join: t in Task,
      on: t.id == s.task_id,
      join: v in Version,
      on: v.id == r.version_id,
      join: a in Actor,
      on: a.id == r.reviewer_id,
      join: b in Actor,
      on: b.id == r.requested_by_id,
      left_join: review in Review,
      on: review.id == r.review_id,
      where: r.workspace_id == ^wid,
      order_by: [t.ident, r.number],
      select: %{
        "task" => t.ident,
        "n" => r.number,
        "version" => v.number,
        "reviewer" => a.name,
        "requested_by" => b.name,
        "at" => r.inserted_at,
        "note" => r.note,
        "status" => r.status,
        "close_reason" => r.close_reason,
        "review" => review.number,
        "closed_at" => r.closed_at
      }
    )
  end

  def query("spec_reviews", wid) do
    from(r in Review,
      join: s in Spec,
      on: s.id == r.spec_id,
      join: t in Task,
      on: t.id == s.task_id,
      join: v in Version,
      on: v.id == r.version_id,
      join: a in Actor,
      on: a.id == r.reviewer_id,
      where: r.workspace_id == ^wid,
      order_by: [t.ident, r.number],
      select: %{
        "task" => t.ident,
        "n" => r.number,
        "version" => v.number,
        "reviewer" => a.name,
        "verdict" => r.verdict,
        "summary" => r.summary,
        "at" => r.inserted_at
      }
    )
  end

  def query("spec_issues", wid) do
    from(i in Issue,
      join: s in Spec,
      on: s.id == i.spec_id,
      join: t in Task,
      on: t.id == s.task_id,
      join: r in Review,
      on: r.id == i.review_id,
      where: i.workspace_id == ^wid,
      order_by: [t.ident, r.number, i.number],
      select: %{
        "task" => t.ident,
        "review" => r.number,
        "n" => i.number,
        "severity" => i.severity,
        "file" => i.file,
        "line" => i.line,
        "anchor" => i.anchor,
        "body" => i.body,
        "suggestion" => i.suggestion
      }
    )
  end

  def query("spec_issue_notes", wid) do
    from(n in IssueNote,
      join: i in Issue,
      on: i.id == n.issue_id,
      join: s in Spec,
      on: s.id == i.spec_id,
      join: t in Task,
      on: t.id == s.task_id,
      join: r in Review,
      on: r.id == i.review_id,
      join: a in Actor,
      on: a.id == n.author_id,
      where: n.workspace_id == ^wid,
      order_by: [t.ident, r.number, i.number, n.number],
      select: %{
        "task" => t.ident,
        "review" => r.number,
        "issue" => i.number,
        "n" => n.number,
        "author" => a.name,
        "kind" => n.kind,
        "resolution" => n.resolution,
        "fixed_in_version" => n.fixed_in_version,
        "body" => n.body,
        "at" => n.inserted_at
      }
    )
  end

  def query("spec_events", wid) do
    from(e in Event,
      join: s in Spec,
      on: s.id == e.spec_id,
      join: t in Task,
      on: t.id == s.task_id,
      join: a in Actor,
      on: a.id == e.actor_id,
      where: e.workspace_id == ^wid,
      order_by: [t.ident, e.number],
      select: %{
        "task" => t.ident,
        "n" => e.number,
        "actor" => a.name,
        "action" => e.action,
        "version" => e.version,
        "data" => e.data,
        "at" => e.inserted_at
      }
    )
  end
end
