defmodule HelmsmanWeb.SpecData do
  @moduledoc """
  The task-spec domain functions the web layer uses (add-spec-workflow-ui D13): thin
  wrappers of `Helmsman.TaskSpecs` with the shapes of `add-spec-workflow` design 界面契约
  and `reviews/domain-request-1.md` (R1–R7).

  PLACEHOLDER(add-spec-workflow 3.x): the OpenSpec archive functions (`export_archive/3`,
  `import_archive/4`) are in the domain's third group, not merged yet. They are called on
  `Application.get_env(:helmsman, :spec_archives, Helmsman.TaskSpecs)` and fail with
  `:unavailable` while that module does not export them; the tests configure
  `HelmsmanWeb.SpecArchiveStub`.
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

  @doc "Whether the archive functions are there (the 导出 / 导入 entries)."
  def archives?, do: exported?(:export_archive, 3)

  @doc "`{:ok, %{filename, content_type, body}}` (`version:`, `format:`, `reviews:`)."
  def export_archive(scope, ident, opts), do: archive_call(:export_archive, [scope, ident, opts])

  @doc "A new version from an archive (`base_version:`, `note:`, `dry_run:`), R5."
  def import_archive(scope, ident, binary, opts),
    do: archive_call(:import_archive, [scope, ident, binary, opts])

  defp archive_call(fun, args) do
    if exported?(fun, length(args)),
      do: apply(archives(), fun, args),
      else: {:error, :unavailable}
  end

  defp exported?(fun, arity) do
    mod = archives()
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end

  defp archives, do: Application.get_env(:helmsman, :spec_archives, TaskSpecs)
end
