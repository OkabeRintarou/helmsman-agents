defmodule HelmsmanDaemon.Paths do
  @moduledoc "Private daemon directories and stable machine identity."

  def home, do: Path.expand(System.get_env("HELMSMAN_HOME") || "~/.helmsman")
  def credentials, do: Path.join(home(), "credentials")
  def state, do: Path.join(home(), "state")
  def copilot_home, do: private_dir!(Path.join(home(), "copilot-home"))
  def cursor_root, do: Path.join(home(), "cursor")

  def run(id) when is_integer(id) and id > 0,
    do: Path.join([home(), "runs", Integer.to_string(id)])

  def record(id) when is_integer(id) and id > 0, do: Path.join(state(), "#{id}.json")

  def ensure! do
    Enum.each(
      [home(), state(), Path.join(home(), "runs"), Path.join(home(), "scratch")],
      &private_dir!/1
    )

    machine_id()
  end

  def private_dir!(path) do
    root = home()
    expanded = Path.expand(path)

    unless expanded == root or String.starts_with?(expanded, root <> "/"),
      do: raise(ArgumentError, "directory outside daemon home")

    File.mkdir_p!(expanded)
    chmod_parents(expanded, root)
    expanded
  end

  defp chmod_parents(path, root) do
    File.chmod!(path, 0o700)
    if path != root, do: chmod_parents(Path.dirname(path), root)
  end

  def component!(value) when is_binary(value) do
    if value in ["", ".", ".."] or String.contains?(value, ["/", "\\", <<0>>]),
      do: raise(ArgumentError, "invalid path component")

    value
  end

  def machine_id do
    private_dir!(home())
    path = Path.join(home(), "machine_id")

    case File.read(path) do
      {:ok, value} -> String.trim(value)
      {:error, :enoent} -> create_machine_id(path)
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
    end
  end

  defp create_machine_id(path) do
    value = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        try do
          File.chmod!(path, 0o600)
          IO.binwrite(file, value <> "\n")
        after
          File.close(file)
        end

        value

      {:error, :eexist} ->
        machine_id()

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create", path: path
    end
  end
end
