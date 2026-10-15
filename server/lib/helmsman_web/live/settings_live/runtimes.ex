defmodule HelmsmanWeb.SettingsLive.Runtimes do
  @moduledoc """
  `/w/:slug/settings/runtimes` (spec web-runtimes 运行时页, design D7): the user's
  machines (daemons, every workspace) and the workspace's runtimes (mine, or all with
  `?all=1` for admins), then the workspace's local repositories in the same scope
  (add-local-repositories-ui D4). Panels `?panel=rename:<id>` and `?panel=workspaces:<id>`.

  Web registration (add-local-repo-web-registration D11, `HelmsmanWeb.LocalRepoRegistration`):
  `?panel=register-local-repository` registers a repository on one of the user's own
  machines (machine → candidate → name and workspaces), 移除 on the user's own rows asks
  the machine to drop its entry, and 网页操作记录 lists the requests. Requests wait for
  `{:local_repo_result, request_id, daemon_id, outcome}` (both ids checked) or
  `{:local_repo_timeout, request_id}`; `{:local_repository_changes_changed}` reloads the
  record. Root and path sent to the machine always come from the candidate kept here.

  `{:runtimes_changed}` / `{:daemons_changed}` / `{:local_repositories_changed}` /
  `{:projects_changed}` / `{:local_repository_changes_changed}` (forwarded by the shell)
  reload the lists through
  `HelmsmanWeb.Throttle`; `:tick` every 30 seconds re-reads the machines so the online
  dots follow `last_seen_at` (not the local repositories: the server sets them offline
  and notifies) together with the machines' eligibility and the record. Open panels keep
  their input across reloads.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.AgentComponents

  alias Helmsman.{Daemons, LocalRepositories, Policy, Projects, Runtimes, Workspaces}
  alias HelmsmanWeb.{FormErrors, LocalRepositoryComponents, RunData, Throttle, Url}
  alias HelmsmanWeb.LocalRepoRegistration, as: WebRegistration
  alias HelmsmanWeb.LocalRepoRegistrationComponents, as: RegistrationComponents

  @tick_ms 30_000
  @member_roles [:owner, :admin, :member]
  @register_panel "register-local-repository"
  @name_format ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @not_configured "not configured on the machine"
  @max_candidates 200
  @reread_codes [:root_not_allowed, :missing, :already_registered]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if Policy.authorize(scope, :manage_runtimes) == :ok do
      if connected?(socket), do: :timer.send_interval(@tick_ms, self(), :tick)

      {:ok,
       assign(socket,
         page_title: dgettext("ui", "运行时"),
         admin?: Policy.authorize(scope, :list_all_runtimes) == :ok,
         all?: false,
         uri: nil,
         panel: nil,
         confirm: nil,
         daemons: [],
         runtimes: [],
         local_repositories: [],
         local_projects: %{},
         machines: [],
         changes: [],
         register: nil,
         remove: nil
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, dgettext("ui", "没有权限访问运行时"))
       |> push_navigate(to: "/w/#{scope.workspace.slug}/settings")}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    all? = socket.assigns.admin? and params["all"] == "1"
    socket = assign(socket, uri: if(query, do: "#{path}?#{query}", else: path))

    socket =
      if all? != socket.assigns.all? or socket.assigns.runtimes == [],
        do: socket |> assign(:all?, all?) |> load(),
        else: socket

    {:noreply,
     socket |> open_panel(params["panel"]) |> open_register(params["panel"] == @register_panel)}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    runtimes =
      case Runtimes.list(scope, all: socket.assigns.all?) do
        {:ok, runtimes} -> runtimes
        {:error, _} -> []
      end

    socket
    |> assign(daemons: RunData.daemons(scope), runtimes: runtimes)
    |> load_local()
    |> load_registration()
  end

  # D11: the user's own machines (the entry and the panel) and the record.
  defp load_registration(socket) do
    scope = socket.assigns.current_scope

    machines =
      case WebRegistration.machines(scope) do
        {:ok, machines} -> machines
        {:error, _} -> []
      end

    changes =
      case WebRegistration.list_changes(scope, if(socket.assigns.all?, do: :all, else: :mine)) do
        {:ok, changes} -> changes
        {:error, _} -> []
      end

    socket
    |> assign(machines: machines, changes: changes)
    |> refresh_register()
  end

  # D4: mine = repositories of my machines; all (admins) = every repository.
  defp load_local(socket) do
    scope = socket.assigns.current_scope

    repositories =
      case LocalRepositories.list(scope) do
        {:ok, list} when socket.assigns.all? -> list
        {:ok, list} -> Enum.filter(list, &(&1.owner.user_id == scope.user.id))
        {:error, _} -> []
      end

    projects =
      case Projects.list(scope, include_archived: true) do
        {:ok, projects} ->
          projects
          |> Enum.filter(& &1.local_repository_id)
          |> Enum.group_by(& &1.local_repository_id, &%{key: &1.key, archived: !!&1.archived_at})

        {:error, _} ->
          %{}
      end

    assign(socket, local_repositories: repositories, local_projects: projects)
  end

  defp open_panel(socket, panel) do
    case parse_panel(panel, socket.assigns.daemons) do
      nil ->
        assign(socket, :panel, nil)

      {kind, daemon} ->
        case socket.assigns.panel do
          %{kind: ^kind, id: id} = open when id == daemon.id -> assign(socket, :panel, open)
          _ -> assign(socket, :panel, new_panel(socket, kind, daemon))
        end
    end
  end

  defp parse_panel(panel, daemons) when is_binary(panel) do
    with [kind, id] when kind in ["rename", "workspaces"] <- String.split(panel, ":", parts: 2),
         {id, ""} <- Integer.parse(id),
         %{revoked: false} = daemon <- Enum.find(daemons, &(&1.id == id)) do
      {String.to_existing_atom(kind), daemon}
    else
      _ -> nil
    end
  end

  defp parse_panel(_panel, _daemons), do: nil

  defp new_panel(_socket, :rename, daemon),
    do: %{kind: :rename, id: daemon.id, name: daemon.name, errors: %{}, error: nil}

  defp new_panel(socket, :workspaces, daemon) do
    candidates =
      for %{workspace: w, role: role} <-
            Workspaces.list_for_user(socket.assigns.current_scope.user),
          role in @member_roles,
          do: w

    %{
      kind: :workspaces,
      id: daemon.id,
      candidates: candidates,
      selected: MapSet.new(daemon.workspaces, & &1.id),
      invalid: MapSet.new(),
      error: nil
    }
  end

  ## Web registration (D11)

  # Opened once connected: the panel sends requests and waits for their results.
  defp open_register(socket, true) do
    cond do
      !connected?(socket) -> socket
      socket.assigns.register != nil -> socket
      socket.assigns.machines == [] -> socket
      true -> socket |> assign(:register, new_register()) |> refresh_register()
    end
  end

  defp open_register(socket, false), do: close_register(socket)

  defp close_register(%{assigns: %{register: nil}} = socket), do: socket

  defp close_register(socket) do
    forget_register(socket.assigns.register)
    assign(socket, :register, nil)
  end

  defp forget_register(register) do
    with {:waiting, id} <- register.browse, do: WebRegistration.forget(id)
    if register.submit, do: WebRegistration.forget(register.submit)
    :ok
  end

  defp new_register,
    do: %{
      daemon_id: nil,
      browse: :idle,
      roots: [],
      candidates: [],
      truncated: false,
      filter: "",
      selected: nil,
      name: "",
      workspace_ids: [],
      invalid_workspaces: [],
      errors: %{},
      error: nil,
      reread: false,
      notice: nil,
      submit: nil,
      # The name and workspaces of the pending request; the form is locked meanwhile.
      submitted: nil
    }

  # After the machines changed: keep the selection and the input while the machine is
  # still listed; otherwise start over, auto-selecting the only eligible machine.
  defp refresh_register(%{assigns: %{register: nil}} = socket), do: socket

  defp refresh_register(socket) do
    %{register: register, machines: machines} = socket.assigns

    socket =
      if register.daemon_id && !Enum.any?(machines, &(&1.daemon_id == register.daemon_id)) do
        forget_register(register)
        assign(socket, :register, new_register())
      else
        socket
      end

    case {socket.assigns.register.daemon_id, Enum.filter(machines, &(&1.eligibility == :ok))} do
      {nil, [only]} -> select_machine(socket, only.daemon_id)
      _ -> socket
    end
  end

  defp eligible_machine(socket, daemon_id) do
    Enum.find(socket.assigns.machines, &(&1.daemon_id == daemon_id and &1.eligibility == :ok))
  end

  defp machine_name(socket, daemon_id), do: machine_label(socket.assigns.machines, daemon_id)

  defp select_machine(socket, daemon_id) do
    case eligible_machine(socket, daemon_id) do
      nil ->
        socket

      machine ->
        forget_register(socket.assigns.register)

        socket
        |> assign(:register, %{new_register() | daemon_id: machine.daemon_id})
        |> start_browse()
    end
  end

  defp start_browse(socket) do
    register = socket.assigns.register

    browse =
      case WebRegistration.browse(socket.assigns.current_scope, register.daemon_id) do
        {:ok, request_id} ->
          wait(request_id, WebRegistration.browse_timeout_ms())
          {:waiting, request_id}

        {:error, code} ->
          {:failed, code, nil}
      end

    keep = Map.take(register, [:daemon_id, :name, :workspace_ids])
    assign(socket, :register, new_register() |> Map.merge(keep) |> Map.put(:browse, browse))
  end

  defp wait(request_id, ms), do: Process.send_after(self(), {:local_repo_timeout, request_id}, ms)

  defp update_register(socket, fun) do
    case socket.assigns.register do
      nil -> socket
      register -> assign(socket, :register, fun.(register))
    end
  end

  defp browse_result(socket, {:ok, %{roots: roots, repositories: repositories} = result}) do
    candidates =
      repositories
      |> Enum.take(@max_candidates)
      |> Enum.with_index(&Map.put(&1, :index, &2))

    update_register(
      socket,
      &%{
        &1
        | browse: :ready,
          roots: roots,
          candidates: candidates,
          truncated: Map.get(result, :truncated, false) == true
      }
    )
  end

  defp browse_result(socket, {:error, code, message}),
    do: update_register(socket, &%{&1 | browse: {:failed, code, message}})

  defp select_candidate(socket, index) do
    %{register: register, current_scope: scope} = socket.assigns

    with nil <- register.submit,
         %{registered_as: nil} = candidate <- Enum.at(register.candidates, index),
         %{} = machine <- eligible_machine(socket, register.daemon_id) do
      current = scope.workspace.id
      default = if Enum.any?(machine.workspaces, &(&1.id == current)), do: [current], else: []

      assign(socket, :register, %{
        register
        | selected: candidate.index,
          name: candidate.name || "",
          workspace_ids: default,
          invalid_workspaces: [],
          errors: %{},
          error: nil,
          reread: false,
          notice: nil
      })
    else
      _ -> socket
    end
  end

  defp register_input(socket, params) do
    machine =
      Enum.find(socket.assigns.machines, &(&1.daemon_id == socket.assigns.register.daemon_id))

    allowed = if machine, do: Enum.map(machine.workspaces, & &1.id), else: []
    ids = params |> selected_ids() |> Enum.filter(&(&1 in allowed)) |> Enum.uniq()
    {Map.get(params, "name", socket.assigns.register.name), ids}
  end

  defp input_errors(name, ids, machine) do
    %{}
    |> then(
      &if(Regex.match?(@name_format, name),
        do: &1,
        else: Map.put(&1, :name, code(:invalid_name, machine))
      )
    )
    |> then(&if(ids == [], do: Map.put(&1, :workspaces, dgettext("ui", "至少选择一个工作区")), else: &1))
  end

  defp code(code, machine), do: RegistrationComponents.code_text(code, machine)

  defp submit_register(socket, params) do
    register = socket.assigns.register
    {name, ids} = register_input(socket, params)
    machine = machine_name(socket, register.daemon_id)
    errors = input_errors(name, ids, machine)

    register = %{
      register
      | name: name,
        workspace_ids: ids,
        errors: errors,
        error: nil,
        notice: nil
    }

    candidate = Enum.at(register.candidates, register.selected)

    if errors == %{} do
      # Root and path come from the kept candidate, never from the submitted form.
      attrs = %{root: candidate.root, path: candidate.path, name: name, workspace_ids: ids}

      socket.assigns.current_scope
      |> WebRegistration.register(register.daemon_id, attrs)
      |> case do
        {:ok, request_id} ->
          wait(request_id, WebRegistration.change_timeout_ms())

          assign(socket, :register, %{
            register
            | submit: request_id,
              submitted: %{name: name, workspace_ids: ids},
              invalid_workspaces: [],
              reread: false
          })

        {:error, reason} ->
          assign(socket, :register, register_failed(register, reason, nil, machine))
      end
    else
      assign(socket, :register, register)
    end
  end

  defp register_failed(register, %Ecto.Changeset{} = changeset, _message, machine) do
    errors = Keyword.keys(changeset.errors)

    cond do
      :name in errors ->
        %{register | errors: %{name: code(:invalid_name, machine)}}

      :workspace_ids in errors ->
        %{register | errors: %{workspaces: code(:invalid_workspaces, machine)}}

      true ->
        %{register | error: {:invalid_path, nil}, reread: true}
    end
  end

  defp register_failed(register, {:invalid_workspaces, ids}, _message, machine),
    do: %{
      register
      | errors: %{workspaces: code(:invalid_workspaces, machine)},
        invalid_workspaces: ids
    }

  defp register_failed(register, code, _message, machine)
       when code in [:invalid_name, :name_taken],
       do: %{register | errors: %{name: code(code, machine)}}

  defp register_failed(register, :invalid_workspaces, _message, machine),
    do: %{register | errors: %{workspaces: code(:invalid_workspaces, machine)}}

  defp register_failed(register, code, message, _machine),
    do: %{register | error: {code, message}, reread: code in @reread_codes}

  defp change_result(socket, {:ok, result}) do
    register = restore_submitted(socket.assigns.register)
    machine = machine_name(socket, register.daemon_id)
    name = (is_map(result) && Map.get(result, :name)) || register.name

    socket
    |> assign(:register, nil)
    |> put_flash(
      :info,
      dgettext("ui", "已在 %{machine} 上登记 %{name}", machine: machine, name: name)
    )
    |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))
    |> load()
  end

  defp change_result(socket, {:error, code, message}) do
    register = restore_submitted(socket.assigns.register)
    machine = machine_name(socket, register.daemon_id)
    assign(socket, :register, register_failed(register, code, message, machine))
  end

  # Ends the wait with the input the request was sent with, so results and errors
  # describe that request.
  defp restore_submitted(%{submitted: %{name: name, workspace_ids: ids}} = register),
    do: %{register | name: name, workspace_ids: ids, submit: nil, submitted: nil}

  defp restore_submitted(register), do: %{register | submit: nil, submitted: nil}

  defp ask_remove(socket, id) do
    scope = socket.assigns.current_scope

    with %{} = repository <- find(socket.assigns.local_repositories, id),
         true <- removable?(scope, repository),
         %{} <- eligible_machine(socket, repository.daemon_id) do
      workspaces =
        case WebRegistration.remove_workspaces(scope, repository.id) do
          {:ok, workspaces} -> workspaces
          {:error, _} -> [Map.take(scope.workspace, [:id, :slug, :name])]
        end

      projects = Enum.map(socket.assigns.local_projects[repository.id] || [], & &1.key)

      assign(socket, :remove, %{
        id: repository.id,
        name: repository.name,
        daemon_id: repository.daemon_id,
        machine: repository.daemon_name,
        workspaces: workspaces,
        projects: projects,
        waiting: nil,
        error: nil
      })
    else
      _ -> socket
    end
  end

  defp confirm_remove(%{assigns: %{remove: %{waiting: nil} = remove}} = socket) do
    case WebRegistration.remove(socket.assigns.current_scope, remove.id) do
      {:ok, request_id} ->
        wait(request_id, WebRegistration.change_timeout_ms())
        assign(socket, :remove, %{remove | waiting: request_id, error: nil})

      {:error, code} when is_atom(code) ->
        assign(socket, :remove, %{remove | error: {code, nil}})

      {:error, _} ->
        assign(socket, :remove, %{remove | error: {:failed, nil}})
    end
  end

  defp confirm_remove(socket), do: socket

  defp dismiss_remove(%{assigns: %{remove: nil}} = socket), do: socket

  defp dismiss_remove(socket) do
    if socket.assigns.remove.waiting, do: WebRegistration.forget(socket.assigns.remove.waiting)
    assign(socket, :remove, nil)
  end

  defp remove_result(socket, {:ok, _result}) do
    remove = socket.assigns.remove

    socket
    |> assign(:remove, nil)
    |> put_flash(
      :info,
      dgettext("ui", "已从 %{machine} 移除 %{name}", machine: remove.machine, name: remove.name)
    )
    |> load()
  end

  defp remove_result(socket, {:error, code, message}),
    do: assign(socket, :remove, %{socket.assigns.remove | waiting: nil, error: {code, message}})

  ## Events

  @impl true
  def handle_event("validate_rename", %{"rename" => %{"name" => name}}, socket),
    do: {:noreply, update_panel(socket, :rename, &%{&1 | name: name})}

  def handle_event("rename", %{"rename" => %{"name" => name}}, socket) do
    with %{kind: :rename, id: id} <- socket.assigns.panel,
         {:ok, name} <- present(name, socket) do
      case Daemons.rename(socket.assigns.current_scope, id, name) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, dgettext("ui", "已改名")) |> load() |> close_panel()}

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = FormErrors.messages(changeset)
          {:noreply, update_panel(socket, :rename, &%{&1 | name: name, errors: errors})}

        {:error, reason} ->
          {:noreply, panel_error(socket, reason)}
      end
    else
      {:blank, socket} -> {:noreply, socket}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select_workspaces", params, socket) do
    ids = selected_ids(params)
    {:noreply, update_panel(socket, :workspaces, &%{&1 | selected: MapSet.new(ids)})}
  end

  def handle_event("save_workspaces", params, socket) do
    case socket.assigns.panel do
      %{kind: :workspaces, id: id} -> save_workspaces(socket, id, selected_ids(params))
      _ -> {:noreply, socket}
    end
  end

  def handle_event("ask_revoke", %{"id" => id}, socket) do
    case find(socket.assigns.daemons, id) do
      %{revoked: false} = daemon ->
        {:noreply, assign(socket, :confirm, %{kind: :revoke, id: daemon.id, name: daemon.name})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    with %{} = daemon <- find(socket.assigns.daemons, id),
         {:ok, _} <- Daemons.revoke(socket.assigns.current_scope, daemon.id) do
      {:noreply,
       socket
       |> assign(:confirm, nil)
       |> put_flash(:info, dgettext("ui", "已吊销 %{name}", name: daemon.name))
       |> load()}
    else
      nil -> {:noreply, assign(socket, :confirm, nil)}
      {:error, reason} -> {:noreply, failed(socket, reason)}
    end
  end

  def handle_event("ask_disable", %{"id" => id}, socket) do
    case find(socket.assigns.runtimes, id) do
      %{} = runtime -> {:noreply, assign(socket, :confirm, %{kind: :disable, id: runtime.id})}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("disable", %{"id" => id}, socket), do: set_disabled(socket, id, true)
  def handle_event("enable", %{"id" => id}, socket), do: set_disabled(socket, id, false)

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("select_machine", %{"daemon_id" => id}, socket) do
    case {socket.assigns.register, Integer.parse(to_string(id))} do
      {%{submit: nil, daemon_id: current}, {id, ""}} when id != current ->
        {:noreply, select_machine(socket, id)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reread", _params, socket) do
    case socket.assigns.register do
      %{submit: nil, daemon_id: id} when is_integer(id) ->
        if eligible_machine(socket, id),
          do: {:noreply, start_browse(socket)},
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("filter_candidates", params, socket) do
    filter = params |> Map.get("filter", "") |> to_string() |> String.slice(0, 200)
    {:noreply, update_register(socket, &%{&1 | filter: filter})}
  end

  def handle_event("select_candidate", %{"index" => index}, socket) do
    case {socket.assigns.register, Integer.parse(to_string(index))} do
      {%{}, {index, ""}} -> {:noreply, select_candidate(socket, index)}
      _ -> {:noreply, socket}
    end
  end

  # Changes arriving while a request is pending (the form is locked) are ignored.
  def handle_event("validate_register", %{"register" => params}, socket) when is_map(params) do
    case socket.assigns.register do
      %{selected: index, submit: nil} when is_integer(index) ->
        {name, ids} = register_input(socket, params)
        machine = machine_name(socket, socket.assigns.register.daemon_id)
        errors = input_errors(name, ids, machine)

        {:noreply,
         update_register(socket, &%{&1 | name: name, workspace_ids: ids, errors: errors})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("register", %{"register" => params}, socket) when is_map(params) do
    case socket.assigns.register do
      %{selected: index, submit: nil} when is_integer(index) ->
        if eligible_machine(socket, socket.assigns.register.daemon_id),
          do: {:noreply, submit_register(socket, params)},
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("ask_remove", %{"id" => id}, socket), do: {:noreply, ask_remove(socket, id)}
  def handle_event("remove_local", _params, socket), do: {:noreply, confirm_remove(socket)}
  def handle_event("dismiss_remove", _params, socket), do: {:noreply, dismiss_remove(socket)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save_workspaces(socket, id, ids) do
    case Daemons.set_workspaces(socket.assigns.current_scope, id, ids) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("ui", "已更新服务的工作区"))
         |> load()
         |> close_panel()}

      {:error, {:invalid_workspaces, invalid}} ->
        {:noreply,
         update_panel(socket, :workspaces, fn panel ->
           %{
             panel
             | selected: MapSet.new(ids),
               invalid: MapSet.new(invalid),
               error: dgettext("ui", "你在标出的工作区里不能运行 Agent")
           }
         end)}

      {:error, reason} ->
        {:noreply, panel_error(socket, reason)}
    end
  end

  defp set_disabled(socket, id, disabled) do
    scope = socket.assigns.current_scope

    with %{} = runtime <- find(socket.assigns.runtimes, id),
         {:ok, _} <-
           if(disabled,
             do: Runtimes.disable(scope, runtime.id),
             else: Runtimes.enable(scope, runtime.id)
           ) do
      message = if disabled, do: dgettext("ui", "运行时已禁用"), else: dgettext("ui", "运行时已启用")
      {:noreply, socket |> assign(:confirm, nil) |> put_flash(:info, message) |> load()}
    else
      nil -> {:noreply, assign(socket, :confirm, nil)}
      {:error, reason} -> {:noreply, failed(socket, reason)}
    end
  end

  @impl true
  def handle_info(message, socket)
      when message in [
             {:runtimes_changed},
             {:daemons_changed},
             {:local_repositories_changed},
             {:local_repository_changes_changed},
             {:projects_changed}
           ],
      do: {:noreply, Throttle.schedule(socket)}

  # D8: only the request this page sent, answered by the machine it was sent to.
  def handle_info({:local_repo_result, request_id, daemon_id, outcome}, socket) do
    case pending(socket, request_id) do
      {:browse, ^daemon_id} ->
        WebRegistration.forget(request_id)
        {:noreply, browse_result(socket, outcome)}

      {:register, ^daemon_id} ->
        WebRegistration.forget(request_id)
        {:noreply, change_result(socket, outcome)}

      {:remove, ^daemon_id} ->
        WebRegistration.forget(request_id)
        {:noreply, remove_result(socket, outcome)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:local_repo_timeout, request_id}, socket) do
    case pending(socket, request_id) do
      {:browse, _} ->
        WebRegistration.forget(request_id)
        {:noreply, update_register(socket, &%{&1 | browse: :timeout})}

      {:register, daemon_id} ->
        WebRegistration.forget(request_id)
        notice = code(:timeout, machine_name(socket, daemon_id))
        {:noreply, update_register(socket, &%{restore_submitted(&1) | notice: notice})}

      {:remove, _} ->
        WebRegistration.forget(request_id)
        {:noreply, update(socket, :remove, &%{&1 | waiting: nil, error: {:timeout, nil}})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info(:reload, socket), do: {:noreply, socket |> Throttle.done() |> load()}

  def handle_info(:tick, socket) do
    {:noreply,
     socket
     |> assign(:daemons, RunData.daemons(socket.assigns.current_scope))
     |> load_registration()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp pending(socket, request_id) do
    %{register: register, remove: remove} = socket.assigns

    cond do
      register && register.browse == {:waiting, request_id} -> {:browse, register.daemon_id}
      register && register.submit == request_id -> {:register, register.daemon_id}
      remove && remove.waiting == request_id -> {:remove, remove.daemon_id}
      true -> nil
    end
  end

  defp failed(socket, reason) do
    socket |> assign(:confirm, nil) |> put_flash(:error, error_message(reason)) |> load()
  end

  defp panel_error(socket, reason) do
    case socket.assigns.panel do
      nil -> failed(socket, reason)
      panel -> assign(socket, :panel, %{panel | error: error_message(reason)})
    end
  end

  defp error_message(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  defp error_message(:not_found), do: dgettext("ui", "运行时不存在")
  defp error_message(_reason), do: dgettext("ui", "操作失败，请重试")

  defp present(name, socket) do
    if String.trim(name) == "" do
      errors = %{name: [dgettext("ui", "请填写名字")]}
      {:blank, update_panel(socket, :rename, &%{&1 | name: name, errors: errors})}
    else
      {:ok, name}
    end
  end

  defp update_panel(socket, kind, fun) do
    case socket.assigns.panel do
      %{kind: ^kind} = panel -> assign(socket, :panel, fun.(panel))
      _ -> socket
    end
  end

  defp close_panel(socket) do
    socket
    |> assign(:panel, nil)
    |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))
  end

  defp selected_ids(params) do
    params
    |> Map.get("workspace_ids", [])
    |> List.wrap()
    |> Enum.flat_map(fn id ->
      case Integer.parse(to_string(id)) do
        {id, ""} -> [id]
        _ -> []
      end
    end)
  end

  defp find(list, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Enum.find(list, &(&1.id == id))
      _ -> nil
    end
  end

  ## Rendering

  defp can_toggle?(scope, runtime),
    do: Policy.authorize(scope, :disable_runtime, %{user_id: runtime.daemon.user.id}) == :ok

  defp panel_path(uri, kind, id), do: Url.put_params(uri, %{panel: "#{kind}:#{id}"})

  defp machine_label(machines, daemon_id) do
    case Enum.find(machines, &(&1.daemon_id == daemon_id)) do
      %{name: name} -> name
      nil -> ""
    end
  end

  defp register_label(%{submit: id} = register, machines) when is_binary(id),
    do:
      dgettext("ui", "正在等待 %{machine} 确认…", machine: machine_label(machines, register.daemon_id))

  defp register_label(_register, _machines), do: dgettext("ui", "登记")

  defp removable?(scope, repository),
    do:
      repository.owner.user_id == scope.user.id and
        repository.unavailable_reason != @not_configured

  defp remove_reason(machines, repository) do
    case Enum.find(machines, &(&1.daemon_id == repository.daemon_id)) do
      %{eligibility: :ok} -> nil
      %{eligibility: code, name: name} -> RegistrationComponents.code_text(code, name)
      nil -> RegistrationComponents.code_text(:not_found, repository.daemon_name)
    end
  end

  defp repos_add_command(slug), do: RegistrationComponents.repos_add_command(slug)

  defp login_command, do: "helmsman login --server #{HelmsmanWeb.Endpoint.url()}"

  defp panel_title(%{kind: :rename}), do: dgettext("ui", "改名")
  defp panel_title(%{kind: :workspaces}), do: dgettext("ui", "服务的工作区")
  defp panel_title(_), do: ""

  defp confirm_title(%{kind: :revoke, name: name}), do: dgettext("ui", "吊销 %{name}？", name: name)
  defp confirm_title(%{kind: :disable}), do: dgettext("ui", "禁用运行时？")
  defp confirm_title(_), do: ""

  defp confirm_text(%{kind: :revoke}),
    do: dgettext("ui", "吊销后这台机器立即断开，它的运行时全部离线，需要重新 helmsman login")

  defp confirm_text(%{kind: :disable}),
    do: dgettext("ui", "已绑定的 Agent 不会再被派发运行，排队中的运行会被取消")

  defp confirm_text(_), do: ""

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        empty?: assigns.daemons == [] and assigns.runtimes == [],
        close_path: Url.drop_params(assigns.uri || "", ["panel"])
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={dgettext("ui", "运行时")} />
      </:header>
      <div class="mx-auto w-full max-w-5xl px-4 pt-6 pb-10 sm:px-6">
        <div
          :if={@empty?}
          id="runtimes-empty"
          class="flex flex-col items-center gap-4 rounded-box border border-border bg-surface px-6 py-10 text-center"
        >
          <.icon name="lucide-server" class="size-8 text-fg-subtle" />
          <p class="max-w-md text-body text-fg-muted">
            {dgettext("ui", "在你的电脑上安装 Helmsman 守护进程并登录，它会把检测到的 Agent CLI 登记为运行时")}
          </p>
          <div class="flex w-full max-w-lg flex-col gap-2 text-left">
            <.copy_command id="login-command" text={login_command()} />
            <.copy_command id="start-command" text="helmsman daemon start" />
          </div>
        </div>

        <section :if={!@empty?} id="daemons-section" class="mb-8">
          <h2 class="mb-2 text-title font-semibold text-fg">{dgettext("ui", "我的机器")}</h2>
          <p :if={@daemons == []} class="text-body text-fg-muted">{dgettext("ui", "还没有登录过的机器")}</p>
          <ul class="flex flex-col divide-y divide-border rounded-box border border-border bg-surface">
            <li
              :for={d <- @daemons}
              id={"daemon-#{d.id}"}
              class="flex items-center gap-3 px-4 py-3"
              data-revoked={d.revoked}
            >
              <.presence_dot status={if(d.online, do: :online, else: :offline)} />
              <div class="flex min-w-0 flex-1 flex-col">
                <span class="flex items-center gap-2 text-body text-fg">
                  <span class="truncate font-medium" data-daemon-name>{d.name}</span>
                  <.badge :if={d.revoked} tone={:danger} data-revoked-badge>
                    {dgettext("ui", "已吊销")}
                  </.badge>
                </span>
                <span class="flex flex-wrap items-center gap-x-2 text-caption text-fg-muted">
                  <span>{d.os} / {d.arch}</span>
                  <span>v{d.version}</span>
                  <span :if={d.last_seen_at}>
                    {dgettext("ui", "最近上报")}
                    <.relative_time id={"daemon-#{d.id}-seen"} at={d.last_seen_at} />
                  </span>
                  <span data-daemon-workspaces>
                    {Enum.map_join(d.workspaces, "、", & &1.name)}
                  </span>
                </span>
              </div>
              <.dropdown
                :if={!d.revoked}
                id={"daemon-#{d.id}-actions"}
                label={dgettext("ui", "更多操作")}
                align={:end}
                items={[
                  %{
                    id: "daemon-#{d.id}-rename",
                    label: dgettext("ui", "改名"),
                    icon: "lucide-pencil",
                    patch: panel_path(@uri, "rename", d.id)
                  },
                  %{
                    id: "daemon-#{d.id}-workspaces",
                    label: dgettext("ui", "服务的工作区"),
                    icon: "lucide-layers",
                    patch: panel_path(@uri, "workspaces", d.id)
                  },
                  %{
                    id: "daemon-#{d.id}-revoke",
                    label: dgettext("ui", "吊销"),
                    icon: "lucide-ban",
                    danger: true,
                    on_select: "ask_revoke",
                    value: %{id: d.id}
                  }
                ]}
              >
                <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
              </.dropdown>
            </li>
          </ul>
        </section>

        <section :if={!@empty? or @admin?} id="runtimes-section" class={@empty? && "mt-8"}>
          <div class="mb-2 flex items-center justify-between gap-2">
            <h2 class="text-title font-semibold text-fg">{dgettext("ui", "运行时")}</h2>
            <nav
              :if={@admin?}
              id="runtimes-scope"
              class="flex gap-1"
              aria-label={dgettext("ui", "范围")}
            >
              <.link
                id="runtimes-mine"
                patch={Url.drop_params(@uri || "", ["all"])}
                aria-current={!@all? && "page"}
                class={[
                  "rounded-field px-2 py-1 text-body",
                  !@all? && "bg-selected text-fg",
                  @all? && "text-fg-muted hover:bg-hover"
                ]}
              >
                {dgettext("ui", "我的")}
              </.link>
              <.link
                id="runtimes-all"
                patch={Url.put_params(@uri || "", %{all: "1"})}
                aria-current={@all? && "page"}
                class={[
                  "rounded-field px-2 py-1 text-body",
                  @all? && "bg-selected text-fg",
                  !@all? && "text-fg-muted hover:bg-hover"
                ]}
              >
                {dgettext("ui", "全部")}
              </.link>
            </nav>
          </div>
          <p :if={@runtimes == []} id="runtimes-none" class="text-body text-fg-muted">
            {dgettext("ui", "本工作区还没有运行时")}
          </p>
          <div
            :if={@runtimes != []}
            class="overflow-x-auto rounded-box border border-border bg-surface"
          >
            <table id="runtimes" class="w-full text-body">
              <caption class="sr-only">{dgettext("ui", "运行时")}</caption>
              <thead class="text-left text-caption text-fg-muted">
                <tr class="border-b border-border">
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "机器")}</th>
                  <th :if={@all?} class="px-3 py-2 font-medium">{dgettext("ui", "所属用户")}</th>
                  <th class="px-3 py-2 font-medium">CLI</th>
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "版本")}</th>
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "模型")}</th>
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "状态")}</th>
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "绑定的 Agent")}</th>
                  <th class="px-3 py-2"><span class="sr-only">{dgettext("ui", "操作")}</span></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-border">
                <tr :for={r <- @runtimes} id={"runtime-#{r.id}"}>
                  <td class="px-3 py-2 text-fg" data-machine>{r.daemon.name}</td>
                  <td :if={@all?} class="px-3 py-2 text-fg-muted" data-owner>{r.daemon.user.name}</td>
                  <td class="px-3 py-2"><.provider provider={r.provider} /></td>
                  <td class="px-3 py-2 text-fg-muted">{r.cli_version}</td>
                  <td class="px-3 py-2 text-fg-muted">
                    <span
                      :if={r.models != []}
                      class="hm-tooltip-host relative"
                      tabindex="0"
                      data-models
                    >
                      {length(r.models)}
                      <span role="tooltip" class={tooltip_class(:bottom)}>{Enum.join(r.models, "、")}</span>
                    </span>
                  </td>
                  <td class="px-3 py-2">
                    <.runtime_badge id={"runtime-#{r.id}-status"} runtime={r} />
                  </td>
                  <td class="px-3 py-2">
                    <span class="flex flex-wrap gap-x-2">
                      <.link
                        :for={name <- r.agents}
                        navigate={Url.agent_path(@current_scope.workspace.slug, name)}
                        class="text-brand-fg hover:underline"
                        data-agent={name}
                      >
                        {name}
                      </.link>
                    </span>
                  </td>
                  <td class="px-3 py-2 text-right">
                    <.button
                      :if={can_toggle?(@current_scope, r) and !r.disabled}
                      id={"runtime-#{r.id}-disable"}
                      size="xs"
                      variant="ghost"
                      phx-click="ask_disable"
                      phx-value-id={r.id}
                    >
                      {dgettext("ui", "禁用")}
                    </.button>
                    <.button
                      :if={can_toggle?(@current_scope, r) and r.disabled}
                      id={"runtime-#{r.id}-enable"}
                      size="xs"
                      variant="ghost"
                      phx-click="enable"
                      phx-value-id={r.id}
                    >
                      {dgettext("ui", "启用")}
                    </.button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section :if={!@empty?} id="local-repositories-section" class="mt-8">
          <div class="mb-2 flex items-start justify-between gap-3">
            <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
              <h2 class="text-title font-semibold text-fg">{dgettext("ui", "本地仓库")}</h2>
              <p class="text-caption text-fg-muted">
                {dgettext("ui", "在机器上用")}
                <code class="font-mono">helmsman repos</code>
                {dgettext("ui", "登记；允许网页登记的机器也可以点「登记本地仓库」。路径只保存在机器上")}
              </p>
            </div>
            <.button
              :if={@machines != []}
              id="local-repository-register"
              size="sm"
              icon="lucide-plus"
              class="flex-none"
              patch={Url.put_params(@uri || "", %{panel: "register-local-repository"})}
            >
              {dgettext("ui", "登记本地仓库")}
            </.button>
          </div>
          <div
            :if={@local_repositories == []}
            id="local-repositories-empty"
            class="flex flex-col gap-3 rounded-box border border-border bg-surface px-4 py-4"
          >
            <p class="text-body text-fg-muted">
              {dgettext(
                "ui",
                "把本机的 git 仓库登记给 Helmsman，项目就可以在这台机器上执行而不经过 GitHub"
              )}
            </p>
            <.copy_command
              id="local-repositories-add-command"
              text={repos_add_command(@current_scope.workspace.slug)}
              class="max-w-2xl"
            />
            <p :if={@machines != []} id="local-repositories-empty-web" class="text-body text-fg-muted">
              {dgettext("ui", "也可以在允许网页登记的机器上直接点「登记本地仓库」")}
            </p>
          </div>
          <div
            :if={@local_repositories != []}
            class="overflow-x-auto rounded-box border border-border bg-surface"
          >
            <table id="local-repositories" class="w-full text-body">
              <caption class="sr-only">{dgettext("ui", "本地仓库")}</caption>
              <thead class="text-left text-caption text-fg-muted">
                <tr class="border-b border-border">
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "名字")}</th>
                  <th class="hidden px-3 py-2 font-medium md:table-cell">
                    {dgettext("ui", "机器")}
                  </th>
                  <th :if={@all?} class="px-3 py-2 font-medium">{dgettext("ui", "所属用户")}</th>
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "路径")}</th>
                  <th class="hidden px-3 py-2 font-medium md:table-cell">
                    {dgettext("ui", "默认分支")}
                  </th>
                  <th class="hidden px-3 py-2 font-medium md:table-cell">
                    {dgettext("ui", "状态")}
                  </th>
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "项目")}</th>
                  <th class="px-3 py-2"><span class="sr-only">{dgettext("ui", "操作")}</span></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-border">
                <tr :for={l <- @local_repositories} id={"local-repository-#{l.id}"}>
                  <td class="px-3 py-2 align-top md:align-middle">
                    <span class="font-mono text-fg" data-name>{l.name}</span>
                    <%!-- Narrow screens: the machine and status columns fold in here. --%>
                    <span class="mt-1 flex flex-col items-start gap-1 md:hidden">
                      <span class="text-caption text-fg-muted">{l.daemon_name}</span>
                      <LocalRepositoryComponents.status_badge
                        id={"local-repository-#{l.id}-status-compact"}
                        repository={l}
                        reason
                      />
                    </span>
                  </td>
                  <td class="hidden px-3 py-2 text-fg md:table-cell" data-machine>
                    {l.daemon_name}
                  </td>
                  <td :if={@all?} class="px-3 py-2 text-fg-muted" data-owner>{l.owner.name}</td>
                  <td class="max-w-64 px-3 py-2">
                    <span :if={l.path} class="flex min-w-0 items-center gap-1">
                      <code
                        id={"local-repository-#{l.id}-path-text"}
                        class="min-w-0 truncate font-mono text-label text-fg-muted"
                        title={l.path}
                        data-path
                      >{l.path}</code>
                      <.copy_button
                        id={"local-repository-#{l.id}-path"}
                        text={l.path}
                        label={dgettext("ui", "复制路径")}
                        target={"#local-repository-#{l.id}-path-text"}
                      />
                    </span>
                  </td>
                  <td
                    class="hidden px-3 py-2 font-mono text-fg-muted md:table-cell"
                    data-default-branch
                  >
                    {l.default_branch || "—"}
                  </td>
                  <td class="hidden px-3 py-2 md:table-cell">
                    <LocalRepositoryComponents.status_badge
                      id={"local-repository-#{l.id}-status"}
                      repository={l}
                      reason
                    />
                  </td>
                  <td class="px-3 py-2">
                    <span :if={@local_projects[l.id]} class="flex flex-wrap gap-1">
                      <.link
                        :for={p <- @local_projects[l.id]}
                        navigate={"/w/#{@current_scope.workspace.slug}/p/#{p.key}"}
                        class={[
                          "rounded-badge bg-hover px-1.5 font-mono text-caption hover:underline",
                          p.archived && "text-fg-subtle line-through",
                          !p.archived && "text-fg"
                        ]}
                        data-project={p.key}
                        data-archived={to_string(p.archived)}
                      >
                        {p.key}
                      </.link>
                    </span>
                    <span :if={!@local_projects[l.id]} class="text-fg-subtle">—</span>
                  </td>
                  <td class="px-3 py-2 text-right">
                    <.button
                      :if={removable?(@current_scope, l)}
                      id={"local-repository-remove-#{l.id}"}
                      size="xs"
                      variant="ghost"
                      phx-click="ask_remove"
                      phx-value-id={l.id}
                      disabled_reason={remove_reason(@machines, l)}
                    >
                      {dgettext("ui", "移除")}
                    </.button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <RegistrationComponents.changes
            changes={@changes}
            slug={@current_scope.workspace.slug}
          />
        </section>
      </div>

      <.side_panel
        id="daemon-panel"
        show={@panel != nil}
        title={panel_title(@panel)}
        patch_on_close={@close_path}
      >
        <:error :if={@panel && @panel.error}>{@panel.error}</:error>
        <.form
          :if={@panel && @panel.kind == :rename}
          for={%{}}
          as={:rename}
          id="rename-form"
          phx-change="validate_rename"
          phx-submit="rename"
        >
          <.input
            id="rename-name"
            name="rename[name]"
            label={dgettext("ui", "名字")}
            value={@panel.name}
            maxlength="64"
            errors={Map.get(@panel.errors, :name, [])}
          />
        </.form>
        <.form
          :if={@panel && @panel.kind == :workspaces}
          for={%{}}
          id="workspaces-form"
          phx-change="select_workspaces"
          phx-submit="save_workspaces"
          class="flex flex-col gap-1"
        >
          <input type="hidden" name="workspace_ids[]" value="" />
          <label
            :for={w <- @panel.candidates}
            id={"daemon-workspace-#{w.id}"}
            data-invalid={MapSet.member?(@panel.invalid, w.id)}
            class={[
              "flex items-center gap-2 rounded-field px-2 py-1.5",
              MapSet.member?(@panel.invalid, w.id) && "border border-danger tint-danger"
            ]}
          >
            <input
              type="checkbox"
              name="workspace_ids[]"
              value={w.id}
              checked={MapSet.member?(@panel.selected, w.id)}
              class="size-4 accent-brand"
            />
            <span class="text-body text-fg">{w.name}</span>
          </label>
        </.form>
        <:footer :let={cancel}>
          <span />
          <div class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button
              id="daemon-panel-submit"
              type="submit"
              form={if(@panel && @panel.kind == :rename, do: "rename-form", else: "workspaces-form")}
              variant="primary"
            >
              {dgettext("ui", "保存")}
            </.button>
          </div>
        </:footer>
      </.side_panel>

      <.side_panel
        id="local-repository-register-panel"
        show={@register != nil}
        title={dgettext("ui", "登记本地仓库")}
        width={:wide}
        dirty={@register != nil and @register.selected != nil}
        patch_on_close={@close_path}
      >
        <:error :if={@register && @register.error}>
          <span id="register-error" class="flex flex-col items-start gap-2">
            <RegistrationComponents.code_message
              id="register-error-text"
              code={elem(@register.error, 0)}
              machine={machine_label(@machines, @register.daemon_id)}
              message={elem(@register.error, 1)}
              slug={@current_scope.workspace.slug}
            />
            <.button
              :if={@register.reread}
              id="register-error-reread"
              size="sm"
              phx-click="reread"
              icon="lucide-refresh-cw"
            >
              {dgettext("ui", "重新读取")}
            </.button>
          </span>
        </:error>
        <p
          :if={@register && @register.notice}
          id="register-notice"
          role="status"
          class="mb-4 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
        >
          {@register.notice}
        </p>
        <RegistrationComponents.register_body
          :if={@register}
          register={@register}
          machines={@machines}
          slug={@current_scope.workspace.slug}
        />
        <:footer :let={cancel}>
          <span />
          <div class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button
              id="local-repository-register-submit"
              type="submit"
              form="local-repository-register-form"
              variant="primary"
              disabled={@register == nil or @register.selected == nil or @register.submit != nil}
            >
              {register_label(@register, @machines)}
            </.button>
          </div>
        </:footer>
      </.side_panel>

      <RegistrationComponents.remove_dialog remove={@remove} slug={@current_scope.workspace.slug} />

      <.confirm_dialog
        id="runtimes-confirm"
        show={@confirm != nil}
        title={confirm_title(@confirm)}
        danger
        confirm_label={
          if(@confirm && @confirm.kind == :revoke,
            do: dgettext("ui", "吊销"),
            else: dgettext("ui", "禁用")
          )
        }
        on_confirm={if(@confirm && @confirm.kind == :revoke, do: "revoke", else: "disable")}
        confirm_value={if(@confirm, do: %{id: @confirm.id}, else: %{})}
        on_cancel={JS.push("dismiss")}
      >
        {confirm_text(@confirm)}
      </.confirm_dialog>
    </Layouts.app>
    """
  end
end
