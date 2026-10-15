defmodule HelmsmanWeb.SpecData do
  @moduledoc """
  The task-spec domain functions the web layer uses (add-spec-workflow-ui D13): thin
  wrappers of `Helmsman.TaskSpecs` with the shapes of `add-spec-workflow` design 界面契约
  and `reviews/domain-request-1.md` (R1–R7).
  """

  alias Helmsman.TaskSpecs

  defdelegate summary(scope, ident), to: TaskSpecs
  defdelegate get(scope, ident, opts \\ []), to: TaskSpecs
  defdelegate diff(scope, ident, from, to), to: TaskSpecs
  defdelegate reviews(scope, ident, opts \\ []), to: TaskSpecs
  defdelegate events(scope, ident), to: TaskSpecs
  defdelegate permissions(scope, ident), to: TaskSpecs
  defdelegate attention(scope), to: TaskSpecs

  defdelegate update(scope, ident, attrs), to: TaskSpecs
  defdelegate submit_version(scope, ident, attrs), to: TaskSpecs
  defdelegate request_reviews(scope, ident, reviewers, attrs), to: TaskSpecs
  defdelegate cancel_request(scope, ident, attrs), to: TaskSpecs
  defdelegate submit_review(scope, ident, attrs), to: TaskSpecs
  defdelegate add_note(scope, ident, ref, attrs), to: TaskSpecs
  defdelegate finalize(scope, ident, attrs), to: TaskSpecs
  defdelegate reject(scope, ident, attrs), to: TaskSpecs
  defdelegate abandon(scope, ident, attrs), to: TaskSpecs
  defdelegate reopen(scope, ident, attrs), to: TaskSpecs

  @no_permissions %{
    write: false,
    request_review: false,
    rule: false,
    propose: false,
    approve: false,
    reject: false,
    abandon: false,
    reopen: false
  }

  @doc "All buttons off (when the permissions could not be read)."
  def no_permissions, do: @no_permissions

  defdelegate export_archive(scope, ident, opts), to: TaskSpecs
  defdelegate import_archive(scope, ident, binary, opts), to: TaskSpecs
  defdelegate archive_max_bytes, to: TaskSpecs
end
