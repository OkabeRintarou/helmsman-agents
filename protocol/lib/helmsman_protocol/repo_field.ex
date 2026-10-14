defmodule HelmsmanProtocol.RepoField do
  @moduledoc """
  Field rules shared by the local repository registration messages (protocol 7).

  A `path` is relative to an allowed root: `.` or 1–16 `/`-separated segments,
  none empty, `.` or `..`, without NUL or control characters, at most 1024 bytes.
  """
  alias HelmsmanProtocol.Schema

  @request_id ~r/\A[A-Za-z0-9_-]{22,64}\z/
  @name ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @control ~r/[\x00-\x1F\x7F]/

  @doc """
  Checks a request ID.

      iex> HelmsmanProtocol.RepoField.request_id?("AAAAAAAAAAAAAAAAAAAAAA")
      true
      iex> HelmsmanProtocol.RepoField.request_id?("a.AAAAAAAAAAAAAAAAAAAAA")
      false
  """
  @spec request_id?(term()) :: boolean()
  def request_id?(value), do: is_binary(value) and Regex.match?(@request_id, value)

  @doc "Checks a local repository name (`^[a-z0-9][a-z0-9_-]{0,63}$`)."
  @spec name?(term()) :: boolean()
  def name?(value), do: is_binary(value) and Regex.match?(@name, value)

  @doc "Checks a root label: 1–1024 bytes of UTF-8 without NUL."
  @spec root?(term()) :: boolean()
  def root?(value),
    do:
      is_binary(value) and byte_size(value) in 1..1024 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  @doc """
  Checks a relative path below a root.

      iex> HelmsmanProtocol.RepoField.path?(".")
      true
      iex> HelmsmanProtocol.RepoField.path?("group/lib")
      true
      iex> HelmsmanProtocol.RepoField.path?("../secret")
      false
  """
  @spec path?(term()) :: boolean()
  def path?("."), do: true

  def path?(value) when is_binary(value) and byte_size(value) in 1..1024 do
    segments = String.split(value, "/")

    String.valid?(value) and not Regex.match?(@control, value) and length(segments) <= 16 and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  def path?(_), do: false

  @doc false
  def check(value, [], _path), do: {:ok, value}

  def check(value, [{field, valid?} | rest], path) do
    if valid?.(Map.fetch!(value, field)),
      do: check(value, rest, path),
      else: Schema.invalid(path ++ [Atom.to_string(field)], :type)
  end

  @doc false
  def unique_ids(value, field) do
    ids = Map.fetch!(value, field)

    if length(Enum.uniq(ids)) == length(ids),
      do: {:ok, value},
      else: Schema.invalid([Atom.to_string(field)], :not_allowed)
  end
end
