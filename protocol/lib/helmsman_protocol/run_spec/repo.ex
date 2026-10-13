defmodule HelmsmanProtocol.RunSpec.Repo do
  @moduledoc """
  RunSpec.Repo protocol payload.

  `kind` exists from protocol 3; a missing `kind` means `github`. GitHub
  repositories carry the clone URL and push token; local repositories only carry
  their machine-side `name` and never a path, URL or token.

  `mode` exists from protocol 6; a missing `mode` means `task`. A `snapshot`
  repository is a read-only checkout of `base_branch`: it has no task `branch`
  and no `rescue_branches`.
  """
  use HelmsmanProtocol.Schema
  alias HelmsmanProtocol.Schema

  @github_only [:github_repository_id, :clone_url, :git_token, :git_token_expires_at]

  field(:kind, {:enum, [:github, :local]}, nullable: true)
  field(:mode, {:enum, [:task, :snapshot]}, nullable: true, default: :task)
  field(:name, :string, nullable: true, min_bytes: 1, max_bytes: 255)
  field(:github_repository_id, :pos_integer, nullable: true)
  field(:clone_url, :string, nullable: true, min_bytes: 1)
  field(:base_branch, :string, min_bytes: 1)
  field(:branch, :string, nullable: true, min_bytes: 1)
  list(:rescue_branches, :string)
  field(:git_token, :string, nullable: true, min_bytes: 1)
  field(:git_token_expires_at, :datetime, nullable: true)
  use HelmsmanProtocol.Redacted, [:git_token]

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Schema.error()}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: Schema.invalid([], :type)
  end

  def new(attrs), do: decode(attrs, :native)

  @spec from_wire(map()) :: {:ok, t()} | {:error, Schema.error()}
  def from_wire(attrs), do: decode(attrs, :wire)

  defp decode(attrs, mode) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- precheck(attrs, mode) do
      Schema.decode(__MODULE__, __schema__(), attrs, mode)
    end
  end

  defp decode(attrs, mode), do: Schema.decode(__MODULE__, __schema__(), attrs, mode)

  @doc false
  def validate(%{kind: nil} = repo), do: validate(%{repo | kind: :github})
  def validate(%{mode: nil} = repo), do: validate(%{repo | mode: :task})
  def validate(%{mode: :task, branch: nil}), do: Schema.invalid(["branch"], :required)

  def validate(%{mode: :snapshot, branch: branch}) when not is_nil(branch),
    do: Schema.invalid(["branch"], :not_allowed)

  def validate(%{mode: :snapshot, rescue_branches: [_ | _]}),
    do: Schema.invalid(["rescue_branches"], :not_allowed)

  def validate(repo), do: {:ok, repo}

  defp precheck(attrs, mode) do
    case fetch(attrs, :kind, mode) do
      {:ok, kind} when kind in [:local, "local"] ->
        with :ok <- required([:name], attrs, mode), do: forbidden(@github_only, attrs, mode)

      {:ok, kind} when kind in [nil, :github, "github"] ->
        required(@github_only, attrs, mode)

      :error ->
        required(@github_only, attrs, mode)

      _unknown ->
        :ok
    end
  end

  defp required(fields, attrs, mode) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case fetch(attrs, field, mode) do
        :error -> {:halt, Schema.invalid([Atom.to_string(field)], :required)}
        {:ok, nil} -> {:halt, Schema.invalid([Atom.to_string(field)], :type)}
        {:ok, _} -> {:cont, :ok}
      end
    end)
  end

  defp forbidden(fields, attrs, mode) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case fetch(attrs, field, mode) do
        {:ok, value} when not is_nil(value) ->
          {:halt, Schema.invalid([Atom.to_string(field)], :not_allowed)}

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp fetch(attrs, field, :wire), do: Map.fetch(attrs, Atom.to_string(field))
  defp fetch(attrs, field, :native), do: Map.fetch(attrs, field)
end
