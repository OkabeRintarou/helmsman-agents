defmodule Helmsman.TaskSpecs.Gate do
  @moduledoc """
  The finalize gate (`add-spec-workflow` decisions 6, 8; `task-specs`
  「定稿与批准」). Pure: `check/2` returns the first failing condition, in
  this order:

    1. the spec has a version (`no_version`) and `version` is the latest
       (`stale_version`, with the latest number);
    2. the spec is not `finalized` / `abandoned` (`closed`);
    3. the latest version passes validation now (`invalid`, with the
       errors);
    4. no P1 / P2 issue is `open` or `disputed` (`unresolved_issues`, with
       their refs); P3 issues never block;
    5. no `requested` review request on the latest version
       (`reviews_pending`, with the reviewers' names).
  """

  @type snapshot :: %{
          required(:status) => atom(),
          required(:latest_version) => non_neg_integer(),
          required(:validation) => %{valid: boolean(), errors: [map()]},
          required(:unresolved) => [String.t()],
          required(:pending) => [String.t()]
        }

  @type reason ::
          {:spec, :no_version}
          | {:spec, :stale_version, pos_integer()}
          | {:spec, :closed, atom()}
          | {:spec, :invalid, [map()]}
          | {:spec, :unresolved_issues, [String.t()]}
          | {:spec, :reviews_pending, [String.t()]}

  @doc "See the module documentation."
  @spec check(snapshot(), term()) :: :ok | {:error, reason()}
  def check(snapshot, version) do
    cond do
      snapshot.latest_version == 0 ->
        {:error, {:spec, :no_version}}

      version != snapshot.latest_version ->
        {:error, {:spec, :stale_version, snapshot.latest_version}}

      snapshot.status in [:finalized, :abandoned] ->
        {:error, {:spec, :closed, snapshot.status}}

      not snapshot.validation.valid ->
        {:error, {:spec, :invalid, snapshot.validation.errors}}

      snapshot.unresolved != [] ->
        {:error, {:spec, :unresolved_issues, snapshot.unresolved}}

      snapshot.pending != [] ->
        {:error, {:spec, :reviews_pending, snapshot.pending}}

      true ->
        :ok
    end
  end
end
