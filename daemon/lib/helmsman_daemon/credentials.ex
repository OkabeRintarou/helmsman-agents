defmodule HelmsmanDaemon.Credentials do
  @moduledoc """
  Private device credentials; inspection never displays the token.

  `[credentials] store` in config.toml chooses where the `hmd_` token lives:

    * `"file"` — in the 0600 `credentials` file (other platforms; one atomic
      replacement commits a new token).
    * `"keychain"` (macOS default) — one login keychain item per token
      generation (`service = "dev.helmsman.daemon"`, `account = "<server_url>
      <daemon_id> <ref>"`). The file holds no token, only pointers: `token_ref`
      (committed generation), `pending` (generation being written) and
      `stale_refs` (superseded generations awaiting deletion). Every keychain
      item of this home is referenced by one of them: pointers are recorded
      before items are created and removed only after items are deleted.

  Keychain writes (`write/2`) follow four steps: record `pending`; create the
  item and read it back; commit the file; delete stale generations. `read/1`
  first resolves a `pending` generation left by a crash: readable → promoted
  (the server already issued it), `:not_found` → dropped, any other read error
  → nothing is touched and the caller gets `{:error, {:keychain, reason}}`.
  """
  require Logger
  alias HelmsmanDaemon.{AtomicFile, Config, CredentialsLock, Paths}

  @enforce_keys [:server_url, :daemon_id, :token, :issued_at]
  defstruct [:server_url, :daemon_id, :token, :issued_at, workspaces: []]

  @type t :: %__MODULE__{}
  @service "dev.helmsman.daemon"

  @doc "Keychain service name of daemon token items."
  def keychain_service, do: @service

  def locked_message do
    "the login keychain is locked; log in to the Mac, or set [credentials] store = \"file\" in config.toml"
  end

  @doc """
  Where tokens are stored: `opts[:store]`, the application environment
  (`:credentials_store`, used by tests), then config.toml.
  """
  def store(opts \\ []) do
    case Keyword.get(opts, :store) || Application.get_env(:helmsman_daemon, :credentials_store) do
      nil -> Config.credentials_store()
      store when store in [:file, :keychain] -> {:ok, store}
    end
  end

  @doc "Reads the credentials, resolving keychain generations; see the module doc."
  def read(opts \\ []) do
    CredentialsLock.with_lock(fn -> read_locked(opts) end)
  end

  defp read_locked(opts) do
    with {:ok, store} <- store(opts),
         {:ok, file} <- load() do
      case store do
        :file -> decode_file(file)
        :keychain -> read_keychain(file, opts)
      end
    end
  end

  @doc "File contents without the token and without touching the keychain."
  def metadata do
    with {:ok, file} <- load(),
         {:ok, issued_at, _} <- DateTime.from_iso8601(file["issued_at"] || ""),
         %{"server_url" => url, "daemon_id" => id} when is_binary(url) and is_integer(id) <- file do
      {:ok,
       %{
         server_url: url,
         daemon_id: id,
         issued_at: issued_at,
         workspaces: Map.get(file, "workspaces", []),
         token_store: if(Map.has_key?(file, "token"), do: "file", else: file["token_store"])
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_credentials}
    end
  end

  @doc "True when a committed token (in the file or the keychain) is recorded."
  def logged_in? do
    case load() do
      {:ok, file} -> is_binary(file["token"]) or is_binary(file["token_ref"])
      _ -> false
    end
  end

  def write(%__MODULE__{} = credentials, opts \\ []) do
    CredentialsLock.with_lock(fn -> write_locked(credentials, opts) end)
  end

  defp write_locked(credentials, opts) do
    Paths.ensure!()

    case store(opts) do
      {:ok, :file} -> write_file(credentials, opts)
      {:ok, :keychain} -> write_keychain(credentials, opts)
      error -> error
    end
  end

  @doc """
  Deletes the credentials file and every keychain item it references (missing
  items are not an error). Items that cannot be deleted stay recorded as
  `stale_refs` and `{:error, :keychain}` is returned.
  """
  def delete(opts \\ []) do
    CredentialsLock.with_lock(fn -> delete_locked(opts) end)
  end

  defp delete_locked(opts) do
    case load() do
      {:ok, file} ->
        case Enum.reject(references(file), &(kc_delete(&1, opts) in [:ok, {:error, :not_found}])) do
          [] ->
            rm()

          failed ->
            save(%{"token_store" => "keychain", "stale_refs" => failed}, :delete, opts)
            {:error, :keychain}
        end

      {:error, :enoent} ->
        :ok

      {:error, _} ->
        rm()
    end
  end

  ## File

  defp load do
    path = Paths.credentials()

    with {:ok, stat} <- File.stat(path),
         :ok <- fix_mode(path, stat.mode),
         {:ok, data} <- File.read(path) do
      case Jason.decode(data) do
        {:ok, map} when is_map(map) -> {:ok, map}
        _ -> {:error, :invalid_credentials}
      end
    end
  end

  defp rm do
    case File.rm(Paths.credentials()) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  defp save(file, event, opts) do
    with :ok <- hook(opts, {:write, event}) do
      AtomicFile.write(
        Paths.credentials(),
        Jason.encode!(file),
        Keyword.take(opts, [:before_rename])
      )
    end
  end

  defp fix_mode(path, mode) do
    if Bitwise.band(mode, 0o777) != 0o600 do
      Logger.warning("credentials permissions corrected to 0600")
      File.chmod(path, 0o600)
    else
      :ok
    end
  end

  defp decode_file(%{"token" => _} = file) do
    with {:ok, issued_at, _} <- DateTime.from_iso8601(file["issued_at"] || ""),
         do: decode(file, file["token"], issued_at)
  end

  defp decode_file(%{"token_store" => "keychain"}), do: {:error, :token_in_keychain}
  defp decode_file(_), do: {:error, :invalid_credentials}

  defp decode(%{"server_url" => url, "daemon_id" => id} = map, "hmd_" <> suffix, time)
       when is_binary(url) and is_integer(id) and id > 0 and byte_size(suffix) > 0 do
    {:ok,
     %__MODULE__{
       server_url: url,
       daemon_id: id,
       token: "hmd_" <> suffix,
       issued_at: time,
       workspaces: Map.get(map, "workspaces", [])
     }}
  end

  defp decode(_, _, _), do: {:error, :invalid_credentials}

  defp write_file(credentials, opts) do
    data = credentials |> Map.from_struct() |> Map.update!(:issued_at, &DateTime.to_iso8601/1)
    AtomicFile.write(Paths.credentials(), Jason.encode!(data), opts)
  end

  ## Keychain: read and startup recovery

  defp read_keychain(file, opts) do
    with {:ok, file} <- recover_pending(file, opts) do
      file = cleanup(file, opts)

      cond do
        Map.has_key?(file, "token") -> migrate(file, opts)
        is_binary(file["token_ref"]) -> committed(file, opts)
        true -> {:error, :enoent}
      end
    end
  end

  defp recover_pending(%{"pending" => %{"ref" => _} = pending} = file, opts) do
    case kc_find(pending, opts) do
      {:ok, _token} ->
        commit(file, pending, opts)

      {:error, :not_found} ->
        dropped = Map.delete(file, "pending")

        case save(dropped, :drop_pending, opts) do
          :ok -> {:ok, dropped}
          error -> error
        end

      {:error, reason} ->
        {:error, {:keychain, reason}}
    end
  end

  defp recover_pending(file, _opts), do: {:ok, file}

  defp committed(file, opts) do
    with {:ok, issued_at, _} <- DateTime.from_iso8601(file["issued_at"] || "") do
      case kc_find(committed_ref(file), opts) do
        {:ok, token} -> decode(file, token, issued_at)
        {:error, :not_found} -> {:error, :token_missing}
        {:error, reason} -> {:error, {:keychain, reason}}
      end
    end
  end

  # A legacy file with the plaintext token: move it into the keychain. Until the
  # commit removes it, the file's token stays the committed one.
  defp migrate(file, opts) do
    with {:ok, credentials} <- decode_file(file) do
      case write_keychain(credentials, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Could not move the daemon token into the keychain (#{inspect(reason)}); " <>
              "keeping it in the credentials file and retrying at the next start"
          )
      end

      {:ok, credentials}
    end
  end

  ## Keychain: write protocol

  defp write_keychain(credentials, opts) do
    with {:ok, file} <- load_for_write(),
         {:ok, file, pending} <- prepare(file, credentials, opts),
         {:ok, file} <- commit(file, pending, opts) do
      hook(opts, {:after, 3})
      cleanup(file, opts)
      :ok
    end
  end

  defp load_for_write do
    case load() do
      {:ok, file} -> {:ok, file}
      {:error, :enoent} -> {:ok, %{}}
      {:error, :invalid_credentials} -> {:ok, %{}}
      error -> error
    end
  end

  # Step 1 (and 2): reuse a pending generation holding this very token (a
  # failed commit being retried), otherwise discard it and record a new one.
  defp prepare(%{"pending" => %{"ref" => _} = pending} = file, credentials, opts) do
    token = credentials.token

    case kc_find(pending, opts) do
      {:ok, ^token} ->
        {:ok, file, pending}

      {:ok, _other} ->
        discard(file, pending, credentials, opts)

      {:error, :not_found} ->
        discard(file, pending, credentials, opts)

      {:error, reason} ->
        {:error, {:keychain, reason}}
    end
  end

  defp prepare(file, credentials, opts), do: record(file, credentials, opts)

  defp discard(file, pending, credentials, opts) do
    case kc_delete(pending, opts) do
      result when result in [:ok, {:error, :not_found}] ->
        record(Map.delete(file, "pending"), credentials, opts)

      {:error, reason} ->
        {:error, {:keychain, reason}}
    end
  end

  defp record(file, credentials, opts) do
    pending = %{
      "ref" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      "server_url" => credentials.server_url,
      "daemon_id" => credentials.daemon_id,
      "issued_at" => DateTime.to_iso8601(credentials.issued_at),
      "workspaces" => credentials.workspaces
    }

    file = Map.put(file, "pending", pending)

    with :ok <- save(file, :pending, opts) do
      hook(opts, {:after, 1})
      create(file, pending, credentials.token, opts)
    end
  end

  # Step 2: create the item and read it back. On any failure the item is
  # deleted; only a successful deletion lets the pointer go.
  defp create(file, pending, token, opts) do
    result =
      with :ok <- kc_add(pending, token, opts) do
        case kc_find(pending, opts) do
          {:ok, ^token} -> :ok
          {:ok, _} -> {:error, {:keychain, :mismatch}}
          {:error, reason} -> {:error, {:keychain, reason}}
        end
      end

    case result do
      :ok ->
        hook(opts, {:after, 2})
        {:ok, file, pending}

      error ->
        if kc_delete(pending, opts) in [:ok, {:error, :not_found}],
          do: save(Map.delete(file, "pending"), :drop_pending, opts)

        error
    end
  end

  # Step 3: the pending generation becomes the committed one in one atomic
  # replacement; the previous generation becomes stale.
  defp commit(file, %{"ref" => pending_ref} = pending, opts) do
    stale =
      case committed_ref(file) do
        %{"ref" => ref} = previous when ref != pending_ref -> [previous]
        _ -> []
      end

    committed =
      file
      |> Map.drop(["pending", "token"])
      |> Map.merge(%{
        "server_url" => pending["server_url"],
        "daemon_id" => pending["daemon_id"],
        "issued_at" => pending["issued_at"],
        "workspaces" => pending["workspaces"] || file["workspaces"] || [],
        "token_store" => "keychain",
        "token_ref" => pending["ref"],
        "stale_refs" => stale_refs(file) ++ stale
      })

    case save(committed, :commit, opts) do
      :ok -> {:ok, committed}
      error -> error
    end
  end

  # Step 4: delete superseded generations; failures keep their pointers.
  defp cleanup(file, opts) do
    stale = stale_refs(file)
    remaining = Enum.reject(stale, &(kc_delete(&1, opts) in [:ok, {:error, :not_found}]))

    if remaining != [] do
      Logger.warning("Could not delete #{length(remaining)} old keychain item(s); will retry")
    end

    if remaining == stale do
      file
    else
      file = Map.put(file, "stale_refs", remaining)

      case save(file, :cleanup, opts) do
        :ok -> :ok
        _ -> Logger.warning("Could not record deleted keychain items; will retry")
      end

      file
    end
  end

  defp committed_ref(%{"token_ref" => ref} = file) when is_binary(ref),
    do: %{"ref" => ref, "server_url" => file["server_url"], "daemon_id" => file["daemon_id"]}

  defp committed_ref(_), do: nil

  defp stale_refs(file) do
    file |> Map.get("stale_refs", []) |> List.wrap() |> Enum.filter(&match?(%{"ref" => _}, &1))
  end

  defp references(file) do
    [committed_ref(file), file["pending"] | stale_refs(file)]
    |> Enum.filter(&match?(%{"ref" => ref} when is_binary(ref), &1))
  end

  ## Keychain access

  defp account(%{"server_url" => url, "daemon_id" => id, "ref" => ref}), do: "#{url} #{id} #{ref}"

  defp keychain(opts) do
    Keyword.get_lazy(opts, :keychain, fn ->
      Application.get_env(:helmsman_daemon, :keychain, {HelmsmanDaemon.Keychain.Security, []})
    end)
  end

  defp kc_add(ref, token, opts) do
    {module, keychain_opts} = keychain(opts)

    case module.add(@service, account(ref), token, keychain_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:keychain, reason}}
    end
  end

  defp kc_find(ref, opts) do
    {module, keychain_opts} = keychain(opts)
    module.find(@service, account(ref), keychain_opts)
  end

  defp kc_delete(ref, opts) do
    {module, keychain_opts} = keychain(opts)
    module.delete(@service, account(ref), keychain_opts)
  end

  defp hook(opts, event) do
    case Keyword.get(opts, :hook) do
      nil -> :ok
      hook -> hook.(event)
    end
  end
end

defimpl Inspect, for: HelmsmanDaemon.Credentials do
  import Inspect.Algebra

  def inspect(credentials, opts) do
    concat([
      "#HelmsmanDaemon.Credentials<",
      to_doc(
        %{
          daemon_id: credentials.daemon_id,
          server_url: credentials.server_url,
          token: "[REDACTED]"
        },
        opts
      ),
      ">"
    ])
  end
end
