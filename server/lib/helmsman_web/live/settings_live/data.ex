defmodule HelmsmanWeb.SettingsLive.Data do
  @moduledoc """
  Data settings `/w/:slug/settings/data` (spec web-data-settings, add-data-settings-ui):
  the user's exports, the import panel (`?panel=import`: upload, dry run, preview,
  confirm), the import history (`?import=<id>`), unclaimed identities with their claims
  (`?panel=assign&actor=<name>`) and external agent transfers (`?panel=transfer&agent=`).

  All domain calls go through `HelmsmanWeb.BackupData` (D2). The uploaded file is
  copied to a `Plug.Upload.random_file!/1` path owned by this process (D4), so it
  disappears with the LiveView; the dry run and the confirmed import use that copy with
  the same options (D5).
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.SettingsComponents
  import HelmsmanWeb.DataSettingsComponents

  alias Helmsman.{Agents, Members}
  alias HelmsmanWeb.BackupData
  alias HelmsmanWeb.SettingsLive.Errors

  @history_limit 50
  @blank_rename %{"from" => "", "to" => ""}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    can? = &BackupData.can?(scope, &1)

    if connected?(socket),
      do: Enum.each(BackupData.topics(scope), &Phoenix.PubSub.subscribe(Helmsman.PubSub, &1))

    socket =
      socket
      |> assign(
        page_title: dgettext("ui", "数据"),
        can_export?: can?.(:export_workspace),
        can_import?: can?.(:import_merge),
        can_replace?: can?.(:import_replace),
        can_view_imports?: can?.(:view_imports),
        can_decide?: can?.(:decide_claim),
        can_transfer?: can?.(:transfer_agent),
        exports: [],
        imports: [],
        unclaimed: [],
        claims: [],
        agents: [],
        members: [],
        panel: nil,
        detail: nil,
        form: nil,
        staged: nil,
        flow: :editing,
        stale?: false,
        confirm: nil,
        uri: nil,
        base_path: "/w/#{scope.workspace.slug}/settings/data"
      )
      |> load_all()

    socket =
      if socket.assigns.can_import?,
        do:
          allow_upload(socket, :import_file,
            accept: ~w(.json .gz),
            max_entries: 1,
            max_file_size: BackupData.max_bytes(),
            auto_upload: true,
            progress: &handle_progress/3
          ),
        else: socket

    {:ok, socket}
  end

  @doc "A DOM-id-safe, injective key for an identity name."
  def dom_key(name), do: Base.url_encode64(name, padding: false)

  ## Loading

  defp load_all(socket), do: socket |> load_exports() |> load_imports() |> load_identities()

  defp load_exports(%{assigns: %{can_export?: false}} = socket), do: socket

  defp load_exports(socket) do
    case BackupData.list_exports(socket.assigns.current_scope) do
      {:ok, rows} -> assign(socket, :exports, rows |> Enum.reject(&expired?/1) |> sort_desc())
      {:error, _} -> socket
    end
  end

  defp load_imports(%{assigns: %{can_view_imports?: false}} = socket), do: socket

  defp load_imports(socket) do
    case BackupData.list_imports(socket.assigns.current_scope) do
      {:ok, rows} -> assign(socket, :imports, Enum.take(rows, @history_limit))
      {:error, _} -> socket
    end
  end

  defp load_identities(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(
      unclaimed: ok_or_empty(BackupData.unclaimed(scope)),
      claims: ok_or_empty(BackupData.list_claims(scope)),
      agents: if(socket.assigns.can_transfer?, do: external_agents(scope), else: []),
      members:
        if(
          socket.assigns.can_decide? or socket.assigns.can_transfer? or
            socket.assigns.can_view_imports?,
          do: ok_or_empty(Members.list(scope)),
          else: []
        )
    )
    |> check_panel()
    |> check_confirm()
  end

  defp external_agents(scope) do
    scope
    |> Agents.list()
    |> ok_or_empty()
    |> Enum.filter(&(&1.kind == "external"))
    |> Enum.map(&%{name: &1.name, owner_id: &1.owner[:id], owner_name: &1.owner[:name]})
  end

  defp ok_or_empty({:ok, rows}), do: rows
  defp ok_or_empty(_), do: []

  defp expired?(%{expires_at: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp expired?(_), do: false

  defp sort_desc(rows), do: Enum.sort_by(rows, & &1.id, :desc)

  ## URL state

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    socket = assign(socket, uri: if(query, do: "#{path}?#{query}", else: path))
    {:noreply, open_panel(socket, params)}
  end

  defp open_panel(socket, %{"import" => id}) do
    with true <- socket.assigns.can_view_imports?,
         {id, ""} <- Integer.parse(id),
         {:ok, row} <- BackupData.get_import(socket.assigns.current_scope, id) do
      socket |> leave_import() |> assign(panel: :detail, detail: row)
    else
      _ -> close_with(socket, dgettext("ui", "导入记录不存在"))
    end
  end

  defp open_panel(socket, %{"panel" => "import"}) do
    if socket.assigns.can_import? do
      form = socket.assigns.form || new_form()
      assign(socket, panel: :import, detail: nil, form: form)
    else
      close_with(socket, nil)
    end
  end

  defp open_panel(socket, %{"panel" => "assign", "actor" => name}) do
    if socket.assigns.can_decide? and name in socket.assigns.unclaimed,
      do: socket |> leave_import() |> assign(panel: {:assign, name}, detail: nil),
      else: close_with(socket, dgettext("ui", "该身份或申请已被处理"))
  end

  defp open_panel(socket, %{"panel" => "transfer", "agent" => name}) do
    if socket.assigns.can_transfer? and Enum.any?(socket.assigns.agents, &(&1.name == name)),
      do: socket |> leave_import() |> assign(panel: {:transfer, name}, detail: nil),
      else: close_with(socket, dgettext("ui", "该 Agent 已不存在或不是外接 Agent"))
  end

  defp open_panel(socket, %{"panel" => _}), do: close_with(socket, nil)

  defp open_panel(socket, _params),
    do: socket |> leave_import() |> assign(panel: nil, detail: nil)

  defp close_with(socket, message) do
    socket = if message, do: put_flash(socket, :error, message), else: socket

    socket
    |> leave_import()
    |> assign(panel: nil, detail: nil)
    |> push_patch(to: socket.assigns.base_path)
  end

  # Leaving the import panel (closing it or switching to another panel) abandons the
  # flow: the staged file and pending uploads go away and results of its imports no
  # longer match, so reopening starts over (D5, code review 1 P2-1).
  defp leave_import(socket) do
    socket
    |> cancel_uploads()
    |> discard_staged()
    |> assign(form: nil, flow: :editing, stale?: false)
  end

  defp cancel_uploads(%{assigns: %{uploads: %{import_file: upload}}} = socket),
    do: Enum.reduce(upload.entries, socket, &cancel_upload(&2, :import_file, &1.ref))

  defp cancel_uploads(socket), do: socket

  # Re-validates the open panel after a reload (D10).
  defp check_panel(%{assigns: %{panel: {:assign, name}}} = socket) do
    if name in socket.assigns.unclaimed,
      do: socket,
      else: close_with(socket, dgettext("ui", "该身份或申请已被处理"))
  end

  defp check_panel(%{assigns: %{panel: {:transfer, name}}} = socket) do
    if Enum.any?(socket.assigns.agents, &(&1.name == name)),
      do: socket,
      else: close_with(socket, dgettext("ui", "该 Agent 已不存在或不是外接 Agent"))
  end

  defp check_panel(socket), do: socket

  # The confirmation dialog must still point at existing objects (code review 1 P2-3).
  defp check_confirm(%{assigns: %{confirm: nil}} = socket), do: socket

  defp check_confirm(socket) do
    message = dgettext("ui", "该身份或申请已被处理")

    confirm = socket.assigns.confirm

    cond do
      confirm_valid?(confirm, socket.assigns) -> socket
      # The assign panel was opened for a target that is gone: close it too.
      match?({:assign, _, _}, confirm) -> socket |> assign(:confirm, nil) |> close_with(message)
      true -> socket |> assign(:confirm, nil) |> put_flash(:error, message)
    end
  end

  defp confirm_valid?({:request, name}, assigns), do: name in assigns.unclaimed

  defp confirm_valid?({:approve, claim}, assigns),
    do: Enum.any?(assigns.claims, &(&1.id == claim.id))

  defp confirm_valid?({:assign, name, member}, assigns),
    do: name in assigns.unclaimed and member(assigns.members, member.user_id) != nil

  ## Export

  @impl true
  def handle_event("export", _params, socket) do
    scope = socket.assigns.current_scope

    case BackupData.request_export(scope) do
      {:ok, row} ->
        if row.user_id != scope.user.id or Enum.any?(socket.assigns.exports, &(&1.id == row.id)) do
          {:noreply, put_flash(socket, :info, dgettext("ui", "已有进行中的导出"))}
        else
          {:noreply,
           socket
           |> assign(:exports, [row | socket.assigns.exports])
           |> put_flash(:info, dgettext("ui", "已开始导出"))}
        end

      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  ## Import form

  def handle_event("validate_import", %{"import" => params}, socket) do
    form = %{params: normalize_params(params, socket)}
    {:noreply, socket |> assign(:form, form) |> invalidate_if_changed()}
  end

  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :import_file, ref)}

  def handle_event("remove_file", _params, socket),
    do: {:noreply, socket |> discard_staged() |> assign(flow: :editing, stale?: false)}

  def handle_event("add_rename", _params, socket) do
    form = socket.assigns.form
    rows = form.params["rename"] ++ [@blank_rename]

    {:noreply,
     socket |> assign(:form, put_in(form.params["rename"], rows)) |> invalidate_if_changed()}
  end

  def handle_event("remove_rename", %{"index" => index}, socket) do
    form = socket.assigns.form
    rows = List.delete_at(form.params["rename"], String.to_integer(index))
    rows = if rows == [], do: [@blank_rename], else: rows

    {:noreply,
     socket |> assign(:form, put_in(form.params["rename"], rows)) |> invalidate_if_changed()}
  end

  def handle_event("dry_run", _params, socket) do
    %{form: form, staged: staged} = socket.assigns

    with %{} <- staged,
         {:ok, opts} <- build_opts(form.params, socket) do
      start(socket, staged.path, Keyword.put(opts, :dry_run, true), fn id ->
        {:dry_running, id, opts}
      end)
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("confirm_import", _params, socket) do
    case {socket.assigns.flow, socket.assigns.staged} do
      {{:previewed, _id, opts, _report}, %{path: path}} ->
        start(socket, path, Keyword.put(opts, :dry_run, false), &{:importing, &1})

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("back_to_edit", _params, socket),
    do: {:noreply, assign(socket, flow: :editing, stale?: false)}

  ## Claims

  def handle_event("request_claim", %{"name" => name}, socket),
    do: {:noreply, assign(socket, :confirm, {:request, name})}

  def handle_event("confirm_request", %{"name" => name}, socket) do
    socket = assign(socket, :confirm, nil)

    case BackupData.request_claim(socket.assigns.current_scope, name) do
      {:ok, _} ->
        {:noreply, socket |> load_identities() |> put_flash(:info, dgettext("ui", "已提交认领申请"))}

      {:error, reason} ->
        {:noreply, claim_failed(socket, reason)}
    end
  end

  def handle_event("cancel_claim", %{"id" => id}, socket) do
    case BackupData.cancel_claim(socket.assigns.current_scope, String.to_integer(id)) do
      {:ok, _} ->
        {:noreply, socket |> load_identities() |> put_flash(:info, dgettext("ui", "已撤回申请"))}

      {:error, reason} ->
        {:noreply, claim_failed(socket, reason)}
    end
  end

  def handle_event("approve_claim", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.claims, &(to_string(&1.id) == id)) do
      nil -> {:noreply, claim_failed(socket, :not_found)}
      claim -> {:noreply, assign(socket, :confirm, {:approve, claim})}
    end
  end

  # `confirm_value` reaches the server as JSON: the id is an integer here, unlike
  # `phx-value-*` strings (found in the browser walkthrough).
  def handle_event("confirm_approve", %{"id" => id}, socket) do
    socket = load_identities(socket)
    claim = Enum.find(socket.assigns.claims, &(to_string(&1.id) == to_string(id)))
    socket = assign(socket, :confirm, nil)

    case claim && BackupData.decide_claim(socket.assigns.current_scope, claim.id, :approve) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_identities()
         |> put_flash(:info, merged_message(claim.actor, claim.user_name))}

      {:error, reason} ->
        {:noreply, claim_failed(socket, reason)}

      nil ->
        {:noreply, claim_failed(socket, :not_found)}
    end
  end

  def handle_event("reject_claim", %{"id" => id}, socket) do
    case BackupData.decide_claim(socket.assigns.current_scope, String.to_integer(id), :reject) do
      {:ok, _} ->
        {:noreply, socket |> load_identities() |> put_flash(:info, dgettext("ui", "已拒绝申请"))}

      {:error, reason} ->
        {:noreply, claim_failed(socket, reason)}
    end
  end

  def handle_event("assign", %{"assign" => %{"user_id" => user_id}}, socket) do
    with {:assign, name} <- socket.assigns.panel,
         %{} = member <- member(socket.assigns.members, user_id) do
      {:noreply, assign(socket, :confirm, {:assign, name, member})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("confirm_assign", _params, socket) do
    socket = load_identities(socket)

    case socket.assigns.confirm do
      {:assign, name, member} -> assign_to(assign(socket, :confirm, nil), name, member)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("transfer", %{"transfer" => %{"user_id" => user_id}}, socket) do
    with {:transfer, name} <- socket.assigns.panel,
         %{} = member <- member(socket.assigns.members, user_id) do
      case BackupData.transfer_agent(socket.assigns.current_scope, name, member.user_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(panel: nil)
           |> load_identities()
           |> put_flash(
             :info,
             dgettext("ui", "已把 %{agent} 转给 %{member}", agent: name, member: member_label(member))
           )
           |> push_patch(to: socket.assigns.base_path)}

        {:error, reason} ->
          {:noreply, claim_failed(socket, reason)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  defp assign_to(socket, name, member) do
    case BackupData.claim_for(socket.assigns.current_scope, name, member.user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(panel: nil)
         |> load_identities()
         |> put_flash(:info, merged_message(name, member_label(member)))
         |> push_patch(to: socket.assigns.base_path)}

      {:error, reason} ->
        {:noreply, claim_failed(socket, reason)}
    end
  end

  ## Realtime

  @impl true
  def handle_info({:export, id}, socket) do
    exports = Enum.reject(socket.assigns.exports, &(&1.id == id))

    exports =
      case BackupData.get_export(socket.assigns.current_scope, id) do
        {:ok, row} -> if expired?(row), do: exports, else: sort_desc([row | exports])
        {:error, _} -> exports
      end

    {:noreply, assign(socket, :exports, exports)}
  end

  def handle_info({:import, id}, socket) do
    socket = load_imports(socket)

    # Only the flow's own import advances it; others refresh the history only (D5, D7).
    # An open detail of the same import follows it (code review 1 P2-2).
    case BackupData.get_import(socket.assigns.current_scope, id) do
      {:ok, row} -> {:noreply, socket |> advance(row) |> sync_detail(row)}
      {:error, _} -> {:noreply, drop_detail(socket, id)}
    end
  end

  def handle_info({:workspace_imported, _id}, socket),
    do: {:noreply, socket |> load_imports() |> load_identities()}

  def handle_info(message, socket)
      when message in [{:claims_changed}, {:actors_changed}, {:members_changed}],
      do: {:noreply, load_identities(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Import flow (D5)

  defp start(socket, path, opts, next) do
    case BackupData.start_import(socket.assigns.current_scope, path, opts) do
      {:ok, row} ->
        {:noreply, socket |> assign(flow: next.(row.id), stale?: false) |> load_imports()}

      {:error, reason} ->
        socket = if reason == :forbidden, do: load_all(socket), else: socket
        {:noreply, assign(socket, flow: {:failed, [%{"reason" => to_string(reason)}]})}
    end
  end

  defp advance(%{assigns: %{flow: {:dry_running, id, opts}}} = socket, %{id: id} = row) do
    case row.status do
      :succeeded -> assign(socket, :flow, {:previewed, id, opts, row.report})
      :failed -> assign(socket, :flow, {:failed, row.errors})
      _ -> socket
    end
  end

  defp advance(%{assigns: %{flow: {:importing, id}}} = socket, %{id: id} = row) do
    case row.status do
      :succeeded ->
        socket
        |> discard_staged()
        |> assign(flow: :editing, form: nil, panel: nil)
        |> load_identities()
        |> put_flash(:info, dgettext("ui", "导入完成"))
        |> push_patch(to: socket.assigns.base_path)

      :failed ->
        assign(socket, :flow, {:failed, row.errors})

      _ ->
        socket
    end
  end

  defp advance(socket, _row), do: socket

  defp sync_detail(%{assigns: %{detail: %{id: id}}} = socket, %{id: id} = row),
    do: assign(socket, :detail, row)

  defp sync_detail(socket, _row), do: socket

  defp drop_detail(%{assigns: %{detail: %{id: id}}} = socket, id),
    do: close_with(socket, dgettext("ui", "导入记录不存在"))

  defp drop_detail(socket, _id), do: socket

  defp invalidate_if_changed(%{assigns: %{flow: {:previewed, _, opts, _}}} = socket) do
    case build_opts(socket.assigns.form.params, socket) do
      {:ok, ^opts} -> socket
      _ -> assign(socket, flow: :editing, stale?: true)
    end
  end

  defp invalidate_if_changed(%{assigns: %{flow: {:failed, _}}} = socket),
    do: assign(socket, :flow, :editing)

  # Inputs are locked while a run is in flight; a change arriving anyway drops the
  # run's id so its result can no longer become a confirmable preview (D5).
  defp invalidate_if_changed(%{assigns: %{flow: {:dry_running, _, _}}} = socket),
    do: assign(socket, flow: :editing, stale?: true)

  defp invalidate_if_changed(%{assigns: %{flow: {:importing, _}}} = socket),
    do: assign(socket, flow: :editing, stale?: true)

  defp invalidate_if_changed(socket), do: socket

  defp handle_progress(:import_file, entry, socket) do
    cond do
      entry.done? and socket.assigns.panel != :import ->
        consume_uploaded_entry(socket, entry, fn _ -> {:ok, nil} end)
        {:noreply, socket}

      entry.done? ->
        stage(socket, entry)

      true ->
        {:noreply, socket}
    end
  end

  defp stage(socket, entry) do
    staged =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        dest = Plug.Upload.random_file!("hm-import")
        File.cp!(path, dest)
        {:ok, %{path: dest, name: entry.client_name, size: entry.client_size}}
      end)

    {:noreply,
     socket
     |> discard_staged()
     |> assign(staged: staged, flow: :editing, stale?: socket.assigns.flow != :editing)}
  end

  defp discard_staged(%{assigns: %{staged: %{path: path}}} = socket) do
    File.rm(path)
    assign(socket, :staged, nil)
  end

  defp discard_staged(socket), do: socket

  defp new_form,
    do: %{
      params: %{
        "source" => "helmsman",
        "mode" => "merge",
        "confirm" => "",
        "rename" => [@blank_rename]
      }
    }

  defp normalize_params(params, socket) do
    rows =
      (params["rename"] || %{})
      |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
      |> Enum.map(fn {_, row} -> %{"from" => row["from"] || "", "to" => row["to"] || ""} end)

    mode =
      if params["mode"] == "replace" and socket.assigns.can_replace?, do: "replace", else: "merge"

    %{
      "source" => if(params["source"] == "bosun", do: "bosun", else: "helmsman"),
      "mode" => mode,
      "confirm" => params["confirm"] || "",
      "rename" => if(rows == [], do: [@blank_rename], else: rows)
    }
  end

  @doc false
  def rename_errors(rows) do
    trimmed = Enum.map(rows, fn row -> {String.trim(row["from"]), String.trim(row["to"])} end)
    froms = trimmed |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == "")) |> Enum.frequencies()

    trimmed
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{"", ""}, _} -> []
      {{from, to}, i} when from == "" or to == "" -> [{i, dgettext("ui", "请填写旧名和新名")}]
      {{from, _}, i} -> if froms[from] > 1, do: [{i, dgettext("ui", "旧名重复")}], else: []
    end)
    |> Map.new()
  end

  defp build_opts(params, socket) do
    errors = rename_errors(params["rename"])
    replace? = params["mode"] == "replace"

    cond do
      errors != %{} ->
        :error

      replace? and params["confirm"] != socket.assigns.current_scope.workspace.slug ->
        :error

      true ->
        rename =
          params["rename"]
          |> Enum.map(&{String.trim(&1["from"]), String.trim(&1["to"])})
          |> Enum.reject(&(&1 == {"", ""}))
          |> Map.new()

        opts = [
          mode: if(replace?, do: :replace, else: :merge),
          source: if(params["source"] == "bosun", do: :bosun, else: :helmsman),
          rename: rename,
          file_name: socket.assigns.staged && socket.assigns.staged.name
        ]

        {:ok, if(replace?, do: opts ++ [confirm: params["confirm"]], else: opts)}
    end
  end

  ## Errors and helpers

  defp failed(socket, reason) do
    socket = if Errors.reload?(reason), do: load_all(socket), else: socket
    put_flash(socket, :error, reason_message(reason))
  end

  defp claim_failed(socket, reason) do
    message =
      case reason do
        :not_found -> dgettext("ui", "该身份或申请已被处理")
        :busy -> dgettext("ui", "工作区正忙，请稍后再试")
        :managed_agent -> dgettext("ui", "托管 Agent 不能转移")
        :forbidden -> Errors.message(:forbidden)
        other -> Errors.message(other)
      end

    socket
    |> assign(:confirm, nil)
    |> load_identities()
    |> put_flash(:error, message)
  end

  defp merged_message(actor, member),
    do: dgettext("ui", "已把 %{actor} 合并到 %{member}", actor: actor, member: member)

  defp member(members, user_id),
    do: Enum.find(members, &(to_string(&1.user_id) == to_string(user_id)))

  defp member_label(member), do: member.actor_name || member.display_name || member.email

  defp member_option(member) do
    name = member.display_name || member.email

    label =
      if name && name != member.actor_name,
        do: "#{member.actor_name}（#{name}）",
        else: member.actor_name

    {label, member.user_id}
  end

  defp user_name(members, user_id) do
    case Enum.find(members, &(&1.user_id == user_id)) do
      nil -> dgettext("ui", "已离开的成员")
      member -> member_label(member)
    end
  end

  defp claims_for(claims, name), do: Enum.filter(claims, &(&1.actor == name))

  defp expires_text(%DateTime{} = at) do
    secs = max(DateTime.diff(at, DateTime.utc_now(), :second), 0)

    if secs >= 3600,
      do: dgettext("ui", "%{n} 小时后过期", n: div(secs + 3599, 3600)),
      else: dgettext("ui", "%{n} 分钟后过期", n: max(div(secs + 59, 60), 1))
  end

  defp expires_text(_), do: nil

  defp import_busy?(imports), do: Enum.any?(imports, &(&1.status in [:queued, :running]))

  defp can_dry_run?(assigns) do
    assigns.staged != nil and assigns.uploads.import_file.entries == [] and
      match?({:ok, _}, build_opts(assigns.form.params, %{assigns: assigns})) and
      (assigns.flow == :editing or match?({:failed, _}, assigns.flow))
  end

  defp confirm_attrs(nil, _assigns),
    do: %{title: "", label: "", event: "dismiss", value: %{}, text: "", danger: false}

  defp confirm_attrs({:request, name}, _assigns) do
    %{
      title: dgettext("ui", "认领 %{name}？", name: name),
      label: dgettext("ui", "申请认领"),
      event: "confirm_request",
      value: %{name: name},
      danger: false,
      text:
        dgettext(
          "ui",
          "申请后由管理员批准；批准后它的全部历史（提出、执行、事件、反馈、提及）会合并到你的身份，无法撤销。"
        )
    }
  end

  defp confirm_attrs({:approve, claim}, _assigns) do
    %{
      title:
        dgettext("ui", "把 %{actor} 合并到 %{member}？", actor: claim.actor, member: claim.user_name),
      label: dgettext("ui", "批准并合并"),
      event: "confirm_approve",
      value: %{id: claim.id},
      danger: true,
      text: dgettext("ui", "此操作无法撤销。合并期间工作区暂停写入。")
    }
  end

  defp confirm_attrs({:assign, name, member}, _assigns) do
    %{
      title:
        dgettext("ui", "把 %{actor} 合并到 %{member}？", actor: name, member: member_label(member)),
      label: dgettext("ui", "合并"),
      event: "confirm_assign",
      value: %{},
      danger: true,
      text: dgettext("ui", "此操作无法撤销。合并期间工作区暂停写入。")
    }
  end

  ## Render

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        slug: assigns.current_scope.workspace.slug,
        me: assigns.current_scope.user.id,
        busy?: import_busy?(assigns.imports),
        dialog: confirm_attrs(assigns.confirm, assigns)
      )

    ~H"""
    <.settings_page tab={:data} flash={@flash} current_scope={@current_scope} shell={@shell}>
      <div>
        <p
          :if={!@can_export?}
          id="data-admin-only"
          role="note"
          class="mb-4 text-body text-fg-muted"
        >
          {dgettext("ui", "导出与导入需要管理员权限")}
        </p>

        <.settings_section
          :if={@can_export?}
          id="data-export"
          title={dgettext("ui", "导出")}
          description={
            dgettext(
              "ui",
              "导出文件只有你能下载，保留 24 小时；不含账号、成员、Token 与 Agent 配置"
            )
          }
        >
          <:actions>
            <.button id="export-button" variant="primary" icon="lucide-download" phx-click="export">
              {dgettext("ui", "导出工作区")}
            </.button>
          </:actions>
          <ul :if={@exports != []} id="exports" class="flex flex-col divide-y divide-border">
            <li
              :for={row <- @exports}
              id={"export-#{row.id}"}
              data-status={row.status}
              class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-body"
            >
              <.relative_time id={"export-#{row.id}-at"} at={row.inserted_at} class="text-fg-muted" />
              <span class={["font-medium", row.status == :failed && "text-danger-fg"]}>
                {export_status_label(row.status)}
              </span>
              <span :if={row.status == :succeeded} class="text-fg-muted">{format_size(row.size)}</span>
              <span :if={row.status == :succeeded} class="min-w-0 flex-1 truncate text-fg-muted">
                {counts_summary(row.counts)}
              </span>
              <span :if={row.status == :succeeded} class="text-caption text-fg-muted">
                {expires_text(row.expires_at)}
              </span>
              <span :if={row.status == :failed} class="min-w-0 flex-1 text-fg-muted">{row.error}</span>
              <.button
                :if={row.status == :succeeded}
                id={"export-#{row.id}-download"}
                size="sm"
                icon="lucide-file-down"
                href={BackupData.download_path(@current_scope, row.id)}
                download
              >
                {dgettext("ui", "下载")}
              </.button>
            </li>
          </ul>
          <p :if={@exports == []} id="exports-empty" class="py-3 text-body text-fg-muted">
            {dgettext("ui", "还没有导出")}
          </p>
        </.settings_section>

        <.settings_section
          :if={@can_import?}
          id="data-import"
          title={dgettext("ui", "导入")}
          description={dgettext("ui", "导入期间工作区暂停写入，请在空闲时进行")}
        >
          <:actions>
            <.button
              id="import-button"
              variant="primary"
              icon="lucide-upload"
              patch={"#{@base_path}?panel=import"}
              disabled={@busy?}
              disabled_reason={if(@busy?, do: dgettext("ui", "已有进行中的导入"))}
            >
              {dgettext("ui", "导入数据")}
            </.button>
          </:actions>
          <ul class="list-disc pl-5 text-body text-fg-muted">
            <li>{dgettext("ui", "合并：按任务新增和快进，只增不删；本地较新的任务会跳过")}</li>
            <li :if={@can_replace?}>
              {dgettext("ui", "替换（仅所有者）：先删除本工作区的全部任务再写入文件")}
            </li>
          </ul>
          <p :if={@busy?} id="import-busy" class="mt-2 text-body text-warning-fg">
            {dgettext("ui", "已有进行中的导入")}
          </p>
        </.settings_section>

        <.settings_section :if={@can_view_imports?} id="data-imports" title={dgettext("ui", "导入记录")}>
          <ul :if={@imports != []} id="imports" class="flex flex-col divide-y divide-border">
            <li :for={row <- @imports} id={"import-#{row.id}"} data-status={row.status}>
              <.link
                patch={"#{@base_path}?import=#{row.id}"}
                class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-body hover:bg-subtle"
              >
                <.relative_time id={"import-#{row.id}-at"} at={row.inserted_at} class="text-fg-muted" />
                <span class="text-fg">{user_name(@members, row.user_id)}</span>
                <span class="min-w-0 flex-1 truncate font-mono text-fg-muted">{row.file_name}</span>
                <span class="text-fg-muted">{source_label(row.source)} · {mode_label(row.mode)}</span>
                <span
                  :if={row.dry_run}
                  class="rounded-field bg-subtle px-1.5 text-caption text-fg-muted"
                >
                  {dgettext("ui", "试运行")}
                </span>
                <span class={["font-medium", row.status == :failed && "text-danger-fg"]}>
                  {status_label(row.status)}
                </span>
              </.link>
            </li>
          </ul>
          <p :if={@imports == []} id="imports-empty" class="py-3 text-body text-fg-muted">
            {dgettext("ui", "还没有导入记录")}
          </p>
        </.settings_section>

        <.settings_section
          id="data-identities"
          title={dgettext("ui", "导入的身份")}
          description={dgettext("ui", "导入时没有对应成员的人会建为未认领的身份；认领后它的历史会合并到你的身份")}
        >
          <ul :if={@unclaimed != []} id="unclaimed" class="flex flex-col divide-y divide-border">
            <li
              :for={name <- @unclaimed}
              id={"unclaimed-#{dom_key(name)}"}
              class="flex flex-wrap items-center gap-x-3 gap-y-2 py-2 text-body"
            >
              <.actor_chip actor={%{name: name, kind: :human, unclaimed: true}} />
              <span class="min-w-0 flex-1" />
              <% claims = claims_for(@claims, name) %>
              <% mine = Enum.find(claims, &(&1.user_id == @me)) %>
              <span :if={mine} class="text-fg-muted">{dgettext("ui", "你已申请")}</span>
              <.button
                :if={mine}
                size="sm"
                variant="ghost"
                phx-click="cancel_claim"
                phx-value-id={mine.id}
              >
                {dgettext("ui", "撤回申请")}
              </.button>
              <.button :if={!mine} size="sm" phx-click="request_claim" phx-value-name={name}>
                {dgettext("ui", "这是我")}
              </.button>
              <.button
                :if={@can_decide?}
                size="sm"
                variant="ghost"
                patch={"#{@base_path}?" <> URI.encode_query(%{"panel" => "assign", "actor" => name})}
              >
                {dgettext("ui", "指定给成员…")}
              </.button>
              <ul :if={@can_decide? and claims != []} class="flex w-full flex-col gap-1 pl-6">
                <li
                  :for={claim <- claims}
                  id={"claim-#{claim.id}"}
                  class="flex flex-wrap items-center gap-2 text-fg-muted"
                >
                  <span>{dgettext("ui", "%{user} 申请认领", user: claim.user_name)}</span>
                  <.button
                    size="xs"
                    variant="primary"
                    phx-click="approve_claim"
                    phx-value-id={claim.id}
                  >
                    {dgettext("ui", "批准")}
                  </.button>
                  <.button
                    size="xs"
                    phx-click="reject_claim"
                    phx-value-id={claim.id}
                  >
                    {dgettext("ui", "拒绝")}
                  </.button>
                </li>
              </ul>
            </li>
          </ul>
          <div :if={@unclaimed == []} id="unclaimed-empty">
            <.empty_state icon="lucide-user-check" title={dgettext("ui", "没有待认领的身份")} />
          </div>

          <div :if={@can_transfer?} id="external-agents" class="mt-4 border-t border-border pt-3">
            <h3 class="text-label font-medium text-fg">{dgettext("ui", "外接 Agent")}</h3>
            <p class="text-caption text-fg-muted">
              {dgettext("ui", "导入时建在执行导入者名下的外接 Agent，可以交还给真正的所有者")}
            </p>
            <ul :if={@agents != []} class="mt-2 flex flex-col divide-y divide-border">
              <li
                :for={agent <- @agents}
                id={"agent-#{dom_key(agent.name)}"}
                class="flex items-center gap-3 py-2 text-body"
              >
                <.actor_chip actor={%{name: agent.name, kind: :agent, managed?: false}} />
                <span class="min-w-0 flex-1 truncate text-fg-muted">
                  {dgettext("ui", "所属：%{owner}", owner: agent.owner_name || "—")}
                </span>
                <.button
                  size="sm"
                  variant="ghost"
                  patch={"#{@base_path}?" <> URI.encode_query(%{"panel" => "transfer", "agent" => agent.name})}
                >
                  {dgettext("ui", "转给…")}
                </.button>
              </li>
            </ul>
            <p :if={@agents == []} class="py-2 text-body text-fg-muted">
              {dgettext("ui", "没有外接 Agent")}
            </p>
          </div>
        </.settings_section>
      </div>

      <.import_panel
        :if={@can_import?}
        show={@panel == :import}
        form={@form}
        uploads={@uploads}
        staged={@staged}
        flow={@flow}
        stale?={@stale?}
        can_replace?={@can_replace?}
        can_dry_run?={@form != nil and can_dry_run?(assigns)}
        busy?={@busy?}
        slug={@slug}
        base_path={@base_path}
      />

      <.side_panel
        :if={@can_view_imports?}
        id="import-detail-panel"
        show={@panel == :detail}
        title={dgettext("ui", "导入记录")}
        width={:wide}
        patch_on_close={@base_path}
      >
        <div :if={@detail} id="import-detail" class="flex flex-col gap-4 text-body">
          <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
            <dt class="text-fg-muted">{dgettext("ui", "文件")}</dt>
            <dd class="font-mono">{@detail.file_name}</dd>
            <dt class="text-fg-muted">{dgettext("ui", "发起人")}</dt>
            <dd>{user_name(@members, @detail.user_id)}</dd>
            <dt class="text-fg-muted">{dgettext("ui", "来源 / 模式")}</dt>
            <dd>
              {source_label(@detail.source)} · {mode_label(@detail.mode)}
              <span :if={@detail.dry_run}>· {dgettext("ui", "试运行")}</span>
            </dd>
            <dt class="text-fg-muted">{dgettext("ui", "状态")}</dt>
            <dd>{status_label(@detail.status)}</dd>
            <dt :if={renames(@detail) != []} class="text-fg-muted">{dgettext("ui", "身份改名")}</dt>
            <dd :if={renames(@detail) != []} class="font-mono">
              <span :for={{from, to} <- renames(@detail)} class="block">{from} → {to}</span>
            </dd>
          </dl>
          <.import_report
            :if={@detail.status == :succeeded}
            id="import-detail-report"
            report={@detail.report}
            workspace={@slug}
          />
          <.import_errors
            :if={@detail.status == :failed}
            id="import-detail-errors"
            errors={@detail.errors}
            workspace={@slug}
          />
        </div>
      </.side_panel>

      <.side_panel
        :if={@can_decide?}
        id="assign-panel"
        show={match?({:assign, _}, @panel)}
        title={dgettext("ui", "指定给成员")}
        patch_on_close={@base_path}
      >
        <.form
          :if={match?({:assign, _}, @panel)}
          for={%{}}
          as={:assign}
          id="assign-form"
          phx-submit="assign"
          class="flex flex-col gap-4"
        >
          <p class="text-body text-fg">
            {dgettext("ui", "把 %{actor} 的全部历史合并到所选成员的身份。", actor: elem(@panel, 1))}
          </p>
          <.input
            id="assign-user"
            name="assign[user_id]"
            type="select"
            label={dgettext("ui", "成员")}
            value=""
            options={Enum.map(@members, &member_option/1)}
          />
        </.form>
        <:footer :let={cancel}>
          <span />
          <div class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button id="assign-submit" type="submit" form="assign-form" variant="primary">
              {dgettext("ui", "合并…")}
            </.button>
          </div>
        </:footer>
      </.side_panel>

      <.side_panel
        :if={@can_transfer?}
        id="transfer-panel"
        show={match?({:transfer, _}, @panel)}
        title={dgettext("ui", "转移外接 Agent")}
        patch_on_close={@base_path}
      >
        <.form
          :if={match?({:transfer, _}, @panel)}
          for={%{}}
          as={:transfer}
          id="transfer-form"
          phx-submit="transfer"
          class="flex flex-col gap-4"
        >
          <p class="text-body text-fg">
            {dgettext("ui", "把 %{agent} 转给：", agent: elem(@panel, 1))}
          </p>
          <.input
            id="transfer-user"
            name="transfer[user_id]"
            type="select"
            label={dgettext("ui", "新的所属成员")}
            value=""
            options={
              @members
              |> Enum.filter(&(&1.role in [:member, :admin, :owner]))
              |> Enum.map(&member_option/1)
            }
          />
          <p class="text-caption text-fg-muted">
            {dgettext("ui", "转移后，原所属用户的 Token 不能再以它的身份写入")}
          </p>
        </.form>
        <:footer :let={cancel}>
          <span />
          <div class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button id="transfer-submit" type="submit" form="transfer-form" variant="primary">
              {dgettext("ui", "转移")}
            </.button>
          </div>
        </:footer>
      </.side_panel>

      <.confirm_dialog
        id="data-confirm"
        show={@confirm != nil}
        title={@dialog.title}
        danger={@dialog.danger}
        confirm_label={@dialog.label}
        on_confirm={@dialog.event}
        confirm_value={@dialog.value}
        on_cancel={JS.push("dismiss")}
      >
        {@dialog.text}
      </.confirm_dialog>
    </.settings_page>
    <%!-- Outside the panel's portal and the (inert while a panel is open) shell, so the
         panel's picker can open it and tests can reach it (D4). --%>
    <form
      :if={@can_import?}
      id="import-upload-form"
      phx-change="validate_upload"
      class="sr-only"
      aria-hidden="true"
    >
      <.live_file_input upload={@uploads.import_file} tabindex="-1" />
    </form>
    """
  end

  defp renames(%{options: %{"rename" => rename}}) when is_map(rename), do: Enum.sort(rename)
  defp renames(_), do: []

  attr :show, :boolean, required: true
  attr :form, :map, required: true
  attr :uploads, :map, required: true
  attr :staged, :map, required: true
  attr :flow, :any, required: true
  attr :stale?, :boolean, required: true
  attr :can_replace?, :boolean, required: true
  attr :can_dry_run?, :boolean, required: true
  attr :busy?, :boolean, required: true
  attr :slug, :string, required: true
  attr :base_path, :string, required: true

  defp import_panel(assigns) do
    params = (assigns.form && assigns.form.params) || %{"rename" => [], "mode" => "merge"}

    assigns =
      assign(assigns,
        params: params,
        rename_errors: rename_errors(params["rename"]),
        locked?: assigns.flow != :editing and not match?({:failed, _}, assigns.flow),
        replace?: params["mode"] == "replace"
      )

    ~H"""
    <.side_panel
      id="import-panel"
      show={@show}
      title={dgettext("ui", "导入数据")}
      width={:wide}
      dirty={@staged != nil}
      patch_on_close={@base_path}
    >
      <:error :if={match?({:failed, _}, @flow)}>
        <.import_errors id="import-errors" errors={elem(@flow, 1)} workspace={@slug} />
      </:error>
      <.form
        :if={@form}
        for={%{}}
        as={:import}
        id="import-form"
        phx-change="validate_import"
        phx-submit="dry_run"
        class="flex flex-col gap-4"
      >
        <fieldset disabled={@locked?} class="flex flex-col gap-4">
          <div class="flex flex-col gap-1">
            <span class="text-label font-medium text-fg">{dgettext("ui", "文件")}</span>
            <button
              :if={@staged == nil and @uploads.import_file.entries == []}
              id="import-file-pick"
              type="button"
              phx-hook=".PickFile"
              data-input={@uploads.import_file.ref}
              phx-drop-target={@uploads.import_file.ref}
              class="flex cursor-pointer flex-col items-center gap-1 rounded-field border border-dashed border-border px-4 py-6 text-body text-fg-muted hover:border-fg-muted focus-visible:outline-2"
            >
              <.icon name="lucide-file-up" class="size-5" />
              {dgettext("ui", "选择或拖入 .json / .json.gz 文件（不超过 %{size}）",
                size: format_size(BackupData.max_bytes())
              )}
            </button>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".PickFile">
              export default {
                mounted() {
                  this.el.addEventListener("click", () => document.getElementById(this.el.dataset.input)?.click())
                }
              }
            </script>
            <div
              :for={entry <- @uploads.import_file.entries}
              id={"import-entry-#{entry.ref}"}
              class="flex items-center gap-2 text-body"
            >
              <span class="min-w-0 flex-1 truncate font-mono">{entry.client_name}</span>
              <span class="text-fg-muted">{entry.progress}%</span>
              <.icon_button
                icon="lucide-x"
                size="sm"
                label={dgettext("ui", "取消上传")}
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
              />
              <p
                :for={err <- upload_errors(@uploads.import_file, entry)}
                class="w-full text-caption text-danger-fg"
              >
                {upload_error(err)}
              </p>
            </div>
            <p
              :for={err <- upload_errors(@uploads.import_file)}
              class="text-caption text-danger-fg"
            >
              {upload_error(err)}
            </p>
            <div :if={@staged} id="import-staged" class="flex items-center gap-2 text-body">
              <.icon name="lucide-file-braces" class="size-4 text-fg-muted" />
              <span class="min-w-0 flex-1 truncate font-mono">{@staged.name}</span>
              <span class="text-fg-muted">{format_size(@staged.size)}</span>
              <.icon_button
                id="import-remove-file"
                icon="lucide-x"
                size="sm"
                label={dgettext("ui", "移除文件")}
                phx-click="remove_file"
              />
            </div>
          </div>

          <.input
            id="import-source"
            name="import[source]"
            type="radio"
            label={dgettext("ui", "来源")}
            value={@params["source"]}
            options={[
              {dgettext("ui", "Helmsman 导出"), "helmsman"},
              {dgettext("ui", "bosun 导出"), "bosun"}
            ]}
          />
          <.input
            :if={@can_replace?}
            id="import-mode"
            name="import[mode]"
            type="radio"
            label={dgettext("ui", "模式")}
            value={@params["mode"]}
            options={[{dgettext("ui", "合并"), "merge"}, {dgettext("ui", "替换"), "replace"}]}
          />
          <input :if={!@can_replace?} type="hidden" name="import[mode]" value="merge" />
          <p :if={!@replace?} class="text-caption text-fg-muted">
            {dgettext("ui", "合并只新增和快进，不删除本地数据")}
          </p>

          <div id="import-rename" class="flex flex-col gap-2">
            <span class="text-label font-medium text-fg">{dgettext("ui", "身份改名（可选）")}</span>
            <div
              :for={{row, i} <- Enum.with_index(@params["rename"])}
              id={"rename-#{i}"}
              class="flex flex-wrap items-center gap-2"
            >
              <input
                type="text"
                name={"import[rename][#{i}][from]"}
                value={row["from"]}
                placeholder={dgettext("ui", "旧名")}
                aria-label={dgettext("ui", "旧名")}
                class="hm-input min-w-0 flex-1"
                autocomplete="off"
              />
              <.icon name="lucide-arrow-right" class="size-4 text-fg-muted" />
              <input
                type="text"
                name={"import[rename][#{i}][to]"}
                value={row["to"]}
                placeholder={dgettext("ui", "新名")}
                aria-label={dgettext("ui", "新名")}
                class="hm-input min-w-0 flex-1"
                autocomplete="off"
              />
              <.icon_button
                icon="lucide-trash"
                size="sm"
                label={dgettext("ui", "删除这一行")}
                phx-click="remove_rename"
                phx-value-index={i}
              />
              <p :if={@rename_errors[i]} class="w-full text-caption text-danger-fg">
                {@rename_errors[i]}
              </p>
            </div>
            <.button
              size="sm"
              variant="ghost"
              icon="lucide-plus"
              phx-click="add_rename"
              class="self-start"
            >
              {dgettext("ui", "添加一行")}
            </.button>
          </div>

          <div
            :if={@replace?}
            id="import-replace-warning"
            role="note"
            class="flex flex-col gap-2 rounded-field border border-danger tint-danger p-3 text-body"
          >
            <p class="font-medium text-danger-fg">
              {dgettext("ui", "替换会删除本工作区的全部任务及其事件、反馈、关联、运行与 PR 记录")}
            </p>
            <p class="text-fg">
              {dgettext("ui", "项目、身份与筛选器保留。已有的 hm/<工作区>/<任务> 分支与守护进程上的工作目录不会被清理，需要人工处理。")}
            </p>
            <.input
              id="import-confirm"
              name="import[confirm]"
              type="text"
              label={dgettext("ui", "输入工作区地址 %{slug} 以确认", slug: @slug)}
              value={@params["confirm"]}
              autocomplete="off"
            />
          </div>
        </fieldset>
      </.form>

      <div
        :if={match?({:dry_running, _, _}, @flow)}
        id="import-dry-running"
        class="mt-4 text-body text-fg-muted"
      >
        {dgettext("ui", "正在试运行…")}
      </div>
      <div
        :if={match?({:importing, _}, @flow)}
        id="import-importing"
        class="mt-4 text-body text-fg-muted"
      >
        {dgettext("ui", "正在导入…")}
      </div>
      <p :if={@stale?} id="import-stale" class="mt-4 text-body text-warning-fg">
        {dgettext("ui", "预览已失效，请重新试运行")}
      </p>
      <div
        :if={match?({:previewed, _, _, _}, @flow)}
        id="import-preview"
        class="mt-4 flex flex-col gap-2"
      >
        <h3 class="text-title font-semibold text-fg">{dgettext("ui", "试运行结果")}</h3>
        <.import_report id="import-preview-report" report={elem(@flow, 3)} workspace={@slug} />
      </div>

      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <%= if match?({:previewed, _, _, _}, @flow) do %>
            <.button id="import-back" phx-click="back_to_edit">{dgettext("ui", "返回修改")}</.button>
            <.button
              id="import-confirm-button"
              variant={if @replace?, do: "danger", else: "primary"}
              phx-click="confirm_import"
              phx-disable-with={dgettext("ui", "正在提交…")}
            >
              {if @replace?, do: dgettext("ui", "替换并导入"), else: dgettext("ui", "确认导入")}
            </.button>
          <% else %>
            <.button
              id="import-dry-run"
              type="submit"
              form="import-form"
              variant="primary"
              disabled={!@can_dry_run? or @busy?}
              disabled_reason={if(@busy?, do: dgettext("ui", "已有进行中的导入"))}
            >
              {dgettext("ui", "试运行")}
            </.button>
          <% end %>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp upload_error(:too_large),
    do: dgettext("ui", "文件超过 %{size}", size: format_size(BackupData.max_bytes()))

  defp upload_error(:not_accepted), do: dgettext("ui", "只支持 .json 或 .gz 文件")
  defp upload_error(:too_many_files), do: dgettext("ui", "一次只能导入一个文件")
  defp upload_error(_), do: dgettext("ui", "上传失败")
end
