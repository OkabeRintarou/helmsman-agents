defmodule HelmsmanDaemon.Login do
  @moduledoc "Device-code login and best-effort remote logout."
  alias HelmsmanDaemon.{Credentials, Paths, Release}
  alias HelmsmanProtocol.{DeviceAuth, Machine}

  def machine do
    {:ok, hostname} = :inet.gethostname()

    %Machine{
      machine_id: Paths.machine_id(),
      name: List.to_string(hostname),
      os: :os.type() |> elem(1) |> Atom.to_string(),
      arch: List.to_string(:erlang.system_info(:system_architecture)),
      daemon_version: Release.version()
    }
  end

  def login(server_url, opts \\ []) do
    Paths.ensure!()

    if Credentials.logged_in?() and not Keyword.get(opts, :force, false) do
      IO.puts("Already logged in; logout first or use --force")
      3
    else
      request_code(server_url, opts)
    end
  end

  defp request_code(url, opts) do
    request = %DeviceAuth.CodeRequest{protocol: HelmsmanProtocol.version(), machine: machine()}

    case post(url, DeviceAuth.code_path(), DeviceAuth.CodeRequest.to_wire(request), [], opts) do
      {:ok, %{status: 200, body: body}} ->
        handle_code(body, url, opts)

      reply ->
        http_failure(reply, url)
    end
  end

  defp handle_code(body, url, opts) do
    case DeviceAuth.CodeResponse.from_wire(body) do
      {:ok, code} ->
        IO.puts("Code: #{code.user_code}\nVerify: #{code.verification_uri_complete}")
        clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
        poll(url, code, code.interval, clock.() + code.expires_in * 1_000, clock, opts)

      _ ->
        fail(1, "Invalid device code response")
    end
  end

  defp poll(url, code, interval, deadline, clock, opts) do
    if clock.() + interval * 1_000 >= deadline do
      fail(3, "Device code expired")
    else
      Keyword.get(opts, :sleep, &Process.sleep/1).(interval * 1_000)
      reply = post(url, DeviceAuth.token_path(), %{"device_code" => code.device_code}, [], opts)
      poll_reply(reply, url, code, interval, deadline, clock, opts)
    end
  end

  defp poll_reply(
         {:ok, %{status: status, body: body}},
         url,
         code,
         interval,
         deadline,
         clock,
         opts
       ) do
    case DeviceAuth.decode_token_reply(status, body) do
      {:ok, token} ->
        credentials = %Credentials{
          server_url: url,
          daemon_id: token.daemon_id,
          token: token.token,
          issued_at: DateTime.utc_now(),
          workspaces: Enum.map(token.workspaces, &DeviceAuth.Workspace.to_wire/1)
        }

        save(credentials)

      {:pending, :authorization_pending} ->
        poll(url, code, interval, deadline, clock, opts)

      {:pending, :slow_down} ->
        poll(url, code, interval + 5, deadline, clock, opts)

      {:error, :unsupported_protocol} ->
        fail(4, upgrade_message(url))

      {:error, reason} when reason in [:expired_token, :access_denied] ->
        fail(3, Atom.to_string(reason))

      _ ->
        http_failure({:ok, %{status: status}}, url)
    end
  end

  defp poll_reply(reply, url, _code, _interval, _deadline, _clock, _opts),
    do: http_failure(reply, url)

  defp save(credentials) do
    case Credentials.write(credentials) do
      :ok ->
        print_workspaces(credentials.workspaces)
        0

      {:error, {:keychain, _}} ->
        fail(1, "Could not save the token in the keychain: " <> Credentials.locked_message())

      _ ->
        fail(1, "Could not save credentials")
    end
  end

  def logout(opts \\ []) do
    case HelmsmanDaemon.CredentialsLock.with_lock(fn -> logout_locked(opts) end) do
      {:error, reason} ->
        fail(1, "Could not lock credentials: #{inspect(reason)}; credentials kept")

      code ->
        code
    end
  end

  defp logout_locked(opts) do
    result =
      case Credentials.read() do
        {:ok, credentials} ->
          post(
            credentials.server_url,
            DeviceAuth.logout_path(),
            %{},
            [{HelmsmanProtocol.token_header(), credentials.token}],
            opts
          )

        # Logged in, but the token cannot be read to revoke it remotely.
        {:error, {:keychain, _}} ->
          :unreadable

        _ ->
          {:ok, %{status: 200}}
      end

    deleted = Credentials.delete()

    case result do
      {:ok, %{status: status}} when status in 200..299 -> IO.puts("Logged out")
      _ -> IO.puts("Local credentials deleted; revoke this machine on the website")
    end

    case deleted do
      {:error, :keychain} ->
        IO.puts(
          "Some keychain items could not be deleted (is the keychain locked?); run `helmsman logout` again"
        )

        1

      {:error, reason} ->
        IO.puts(
          "Could not delete local credentials: #{inspect(reason)}; run `helmsman logout` again"
        )

        1

      :ok ->
        0
    end
  end

  @doc "Upgrade hint for a server that rejects this daemon's protocol version."
  def upgrade_message(server_url) do
    "Protocol incompatible; upgrade the daemon: curl -fsSL #{String.trim_trailing(server_url, "/")}/install.sh | sh"
  end

  def print_workspaces(workspaces) do
    Enum.each(workspaces, fn workspace ->
      IO.puts("Workspace: #{workspace["slug"]} (#{workspace["name"]})")
    end)
  end

  defp post(url, path, json, headers, opts) do
    req_opts = Keyword.get(opts, :req_options, [])

    Req.post(
      Keyword.merge(
        [url: String.trim_trailing(url, "/") <> path, json: json, headers: headers, retry: false],
        req_opts
      )
    )
  end

  defp http_failure({:ok, %{status: status}}, _url) when status in [401, 403],
    do: fail(3, "Authentication failed")

  defp http_failure({:ok, %{status: 426}}, url), do: fail(4, upgrade_message(url))
  defp http_failure(_, _url), do: fail(1, "Server request failed")

  defp fail(code, message) do
    IO.puts(message)
    code
  end
end
