defmodule HelmsmanWeb.SpecLive.Show do
  @moduledoc """
  `/w/:slug/t/:ident/spec` (spec web-specs; add-spec-workflow-ui D1–D15): the task's spec
  with its 文件 / 对比 / 评审 / 历史 tabs, banners, the right column (versions, pending
  reviews, the finalize gate) and the panels. Tab, version, file, view, line, diff ends,
  review filter and panel are query params; invalid values fall back to defaults.

  Reads (D2): the summary, permissions and the chosen version's file on every load; the
  reviews of the shown version (issue markers and per-file counts) cached per version and
  spec change; the unresolved refs for the gate; the reviews tab and the history only
  while shown. The diff runs in `start_async(:spec_diff, …)`.

  Realtime (D15): `{:spec_changed, task_id}` on `task:<id>` re-reads everything loaded;
  following the latest version switches to a new one with 「<作者> 提交了 v<n>」; an
  explicit `v` stays. Open panels keep their input.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.SpecComponents

  alias Helmsman.{Events, Tasks}

  alias HelmsmanWeb.{
    SpecData,
    SpecErrors,
    SpecPanels,
    SpecReviewForm,
    SpecVersionForm,
    TaskData,
    Url
  }

  @tabs ~w(files diff reviews history)
  @panels ~w(version review request note finalize reject abandon reopen change-id export import)
  @big_file 5000
  @chunk 2000

  @impl true
  def mount(%{"ident" => ident}, _session, socket) do
    scope = socket.assigns.current_scope
    task = fetch_task(scope, ident) || raise HelmsmanWeb.NotFoundError

    if connected?(socket), do: Events.subscribe(Events.topic(:task, task.task_id))

    socket =
      assign(socket,
        task: task,
        ident: task.id,
        slug: scope.workspace.slug,
        page_title: dgettext("ui", "%{ident} 规格 · %{title}", ident: task.id, title: task.title),
        uri: nil,
        params: %{},
        spec: nil,
        perms: SpecData.no_permissions(),
        versions: [],
        version: nil,
        file: nil,
        content: nil,
        source_limit: nil,
        marker_cache: nil,
        markers: %{},
        file_counts: %{},
        refs: [],
        tab_reviews: nil,
        events: nil,
        diff: nil,
        latest_seen: nil,
        confirm_cancel: nil,
        version_form: nil,
        review_form: nil,
        request_panel: nil,
        note_panel: nil,
        finalize_panel: nil,
        reason_panel: nil,
        change_id_panel: nil,
        export_panel: nil,
        import_panel: nil
      )

    socket =
      if SpecData.archives?(),
        do:
          allow_upload(socket, :spec_archive,
            accept: :any,
            max_entries: 1,
            max_file_size: 2_097_152,
            auto_upload: true,
            progress: &handle_progress/3
          ),
        else: socket

    {:ok, socket}
  end

  defp fetch_task(scope, ident) do
    case Tasks.get(scope, ident) do
      {:ok, task} -> task |> Tasks.summary() |> Map.put(:task_id, task.id)
      _ -> nil
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)

    socket
    |> assign(uri: if(query, do: "#{path}?#{query}", else: path), params: params)
    |> load()
    |> open_panel()
    |> then(&{:noreply, &1})
  end

  ## Loading

  defp load(socket) do
    %{current_scope: scope, ident: ident, params: params} = socket.assigns
    perms = ok(SpecData.permissions(scope, ident), SpecData.no_permissions())

    case SpecData.get(scope, ident, version: requested_version(params), files: []) do
      {:ok, %{spec: spec, versions: versions} = data} ->
        socket
        |> assign(spec: spec, versions: versions, perms: perms)
        |> load_version(data.version)
        |> load_gate()
        |> load_tab()
        |> notice_new_version()

      {:error, {:spec, :version_not_found, _}} ->
        socket |> assign(:params, Map.delete(params, "v")) |> load()

      {:error, _} ->
        assign(socket,
          spec: nil,
          versions: [],
          version: nil,
          perms: perms,
          content: nil,
          refs: []
        )
    end
  end

  defp requested_version(params) do
    case Integer.parse(params["v"] || "") do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp load_version(socket, nil),
    do: assign(socket, version: nil, file: nil, content: nil, markers: %{}, file_counts: %{})

  defp load_version(socket, version) do
    paths = Enum.map(version.files, & &1.path)
    wanted = socket.assigns.params["file"]
    file = if wanted in paths, do: wanted, else: default_file(paths)
    %{current_scope: scope, ident: ident} = socket.assigns

    content =
      case file && SpecData.get(scope, ident, version: version.number, files: [file]) do
        {:ok, %{version: %{files: files}}} ->
          Enum.find_value(files, &(&1.path == file && &1.content))

        _ ->
          nil
      end

    lines = if content, do: length(String.split(content, "\n")), else: 0
    limit = if lines > @big_file, do: socket.assigns.source_limit || @chunk

    socket
    |> assign(version: version, file: file, content: content, source_limit: limit)
    |> load_markers()
  end

  defp default_file([]), do: nil

  defp default_file(paths),
    do: if("proposal.md" in paths, do: "proposal.md", else: hd(SpecVersionForm.sort_paths(paths)))

  # The reviews of the shown version (every resolution) for the markers and the counts;
  # read once per version and spec change (spec-review-1 P2-1).
  defp load_markers(socket) do
    %{version: version, spec: spec, marker_cache: cache} = socket.assigns
    key = {version.number, spec.lock_version}

    if cache == key do
      socket
    else
      %{current_scope: scope, ident: ident} = socket.assigns

      issues =
        case SpecData.reviews(scope, ident, version: version.number) do
          {:ok, %{reviews: reviews}} -> Enum.flat_map(reviews, & &1.issues)
          _ -> []
        end

      markers = issues |> Enum.filter(&(&1.file && &1.line)) |> Enum.group_by(&{&1.file, &1.line})

      counts =
        issues
        |> Enum.filter(&(&1.file && unresolved?(&1)))
        |> Enum.frequencies_by(& &1.file)

      assign(socket, marker_cache: key, markers: markers, file_counts: counts)
    end
  end

  defp load_gate(%{assigns: %{spec: %{status: status}}} = socket)
       when status in [:finalized, :abandoned],
       do: assign(socket, :refs, [])

  defp load_gate(socket) do
    %{current_scope: scope, ident: ident} = socket.assigns

    refs =
      case SpecData.reviews(scope, ident, unresolved_only: true) do
        {:ok, %{reviews: reviews}} ->
          for r <- reviews, i <- r.issues, i.severity in [:P1, :P2], do: i.ref

        _ ->
          []
      end

    assign(socket, :refs, refs)
  end

  defp load_tab(socket) do
    %{current_scope: scope, ident: ident, params: params} = socket.assigns

    case tab(params) do
      "reviews" ->
        assign(socket,
          tab_reviews: ok(SpecData.reviews(scope, ident, review_filter(params["reviews"])), nil),
          events: nil
        )

      "history" ->
        assign(socket, events: ok(SpecData.events(scope, ident), []), tab_reviews: nil)

      "diff" ->
        socket |> assign(tab_reviews: nil, events: nil) |> start_diff()

      _ ->
        assign(socket, tab_reviews: nil, events: nil)
    end
  end

  defp review_filter("unresolved"), do: [unresolved_only: true]

  defp review_filter("v" <> n) do
    case Integer.parse(n) do
      {v, ""} -> [version: v]
      _ -> []
    end
  end

  defp review_filter(_), do: []

  defp start_diff(%{assigns: %{spec: %{latest_version: latest}}} = socket) when latest > 0 do
    {from, to} = diff_ends(socket.assigns.params, latest)

    case socket.assigns.diff do
      %{from: ^from, to: ^to, latest: ^latest} ->
        socket

      _ ->
        %{current_scope: scope, ident: ident} = socket.assigns

        socket
        |> cancel_async(:spec_diff)
        |> assign(:diff, %{from: from, to: to, latest: latest, result: nil, error: nil})
        |> start_async(:spec_diff, fn -> SpecData.diff(scope, ident, from, to) end)
    end
  end

  defp start_diff(socket), do: socket

  @doc false
  # The diff ends from `from` / `to` (default the latest and the one before), swapped
  # when `from` is not before `to`.
  def diff_ends(params, latest) do
    to = clamp(int(params["to"]) || latest, 1, latest)
    from = clamp(int(params["from"]) || to - 1, 0, latest)

    cond do
      from < to -> {from, to}
      from > to -> {to, from}
      true -> {max(to - 1, 0), to}
    end
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp int(nil), do: nil
  defp int(n) when is_integer(n), do: n

  defp int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp notice_new_version(%{assigns: %{spec: spec, latest_seen: seen}} = socket) do
    latest = spec.latest_version
    socket = assign(socket, :latest_seen, latest)
    author = author_of(socket, latest)

    socket =
      if seen != nil and latest > seen and following?(socket),
        do:
          put_flash(
            socket,
            :info,
            dgettext("ui", "%{author} 提交了 v%{n}", author: author, n: latest)
          ),
        else: socket

    assign(socket,
      version_form:
        SpecVersionForm.newer(socket.assigns.version_form, %{latest: latest, author: author})
    )
  end

  defp author_of(socket, n),
    do: Enum.find_value(socket.assigns.versions, &(&1.number == n && &1.author))

  defp following?(socket), do: requested_version(socket.assigns.params) == nil

  defp ok({:ok, v}, _default), do: v
  defp ok(_error, default), do: default

  defp tab(params), do: if(params["tab"] in @tabs, do: params["tab"], else: "files")

  ## Panels (D1: `panel=`)

  defp open_panel(socket) do
    panel = socket.assigns.params["panel"]
    panel = if panel in @panels and allowed?(socket, panel), do: panel

    socket
    |> keep_or(:version_form, panel == "version", &new_version_form/1)
    |> keep_or(:review_form, panel == "review", &new_review_form/1)
    |> keep_or(:request_panel, panel == "request", fn _ ->
      %{selected: [], note: "", error: nil}
    end)
    |> keep_or(:note_panel, panel == "note", &new_note_panel/1)
    |> keep_or(:finalize_panel, panel == "finalize", fn _ ->
      %{summary: "", wake: true, error: nil}
    end)
    |> keep_or(:reason_panel, panel in ~w(reject abandon reopen), &new_reason_panel(&1, panel))
    |> keep_or(
      :change_id_panel,
      panel == "change-id",
      &%{value: &1.assigns.spec.change_id, error: nil}
    )
    |> keep_or(:export_panel, panel == "export", &new_export_panel/1)
    |> keep_or(:import_panel, panel == "import", fn _ ->
      %{name: nil, binary: nil, preview: nil, note: "", error: nil, stale: nil}
    end)
  end

  defp keep_or(socket, key, false, _new), do: assign(socket, key, nil)

  defp keep_or(socket, key, true, new) do
    case socket.assigns[key] do
      nil -> assign(socket, key, new.(socket))
      _open -> socket
    end
  end

  defp allowed?(%{assigns: %{spec: spec, perms: p}} = socket, panel) do
    open? = spec != nil and spec.status not in [:finalized, :abandoned]
    versions? = spec != nil and spec.latest_version > 0
    allowed?(panel, p, %{open: open?, versions: versions?, spec: spec != nil}, socket)
  end

  defp allowed?("version", p, _f, _socket), do: p.write

  defp allowed?(panel, p, f, _socket) when panel in ~w(review request),
    do: p.write and f.open and f.versions

  defp allowed?("note", _p, _f, socket), do: note_issue(socket) != nil
  defp allowed?("finalize", p, f, _socket), do: p.approve and f.versions
  defp allowed?("reject", p, _f, _socket), do: p.reject
  defp allowed?("abandon", p, _f, _socket), do: p.abandon
  defp allowed?("reopen", p, _f, _socket), do: p.reopen
  defp allowed?("change-id", p, f, _socket), do: f.spec and p.write
  defp allowed?("export", _p, f, _socket), do: f.versions and SpecData.archives?()
  defp allowed?("import", p, _f, _socket), do: p.write and SpecData.archives?()

  defp new_version_form(socket) do
    %{spec: spec, current_scope: scope, ident: ident} = socket.assigns
    base = (spec && spec.latest_version) || 0
    change_id = if base == 0, do: (spec && spec.change_id) || String.downcase(ident)
    SpecVersionForm.new(base, files_of(scope, ident, base), change_id)
  end

  defp files_of(_scope, _ident, 0), do: %{}

  defp files_of(scope, ident, n) do
    case SpecData.get(scope, ident, version: n) do
      {:ok, %{version: %{files: files}}} -> Map.new(files, &{&1.path, &1.content})
      _ -> %{}
    end
  end

  defp new_review_form(socket) do
    %{spec: spec, current_scope: scope, ident: ident, params: params} = socket.assigns
    files = scope |> files_of(ident, spec.latest_version) |> line_counts()

    SpecReviewForm.new(spec.latest_version, files, %{
      file: params["file"],
      line: int(params["line"])
    })
  end

  defp line_counts(files), do: Map.new(files, fn {p, c} -> {p, length(String.split(c, "\n"))} end)

  defp note_issue(%{assigns: %{params: %{"issue" => ref}, current_scope: scope, ident: ident}}) do
    case SpecData.reviews(scope, ident) do
      {:ok, %{reviews: reviews}} -> Enum.find_value(reviews, &issue_of(&1, ref))
      _ -> nil
    end
  end

  defp note_issue(_socket), do: nil

  defp issue_of(review, ref) do
    case Enum.find(review.issues, &(&1.ref == ref)) do
      nil -> nil
      issue -> {review, issue}
    end
  end

  defp new_note_panel(socket) do
    {review, issue} = note_issue(socket)
    kinds = note_kinds(socket, review, issue)

    kind =
      case socket.assigns.params["kind"] do
        "reply" -> "accepted"
        "withdraw" -> "withdrawn"
        "rule" -> "upheld"
        _ -> "comment"
      end

    kind = if Enum.any?(kinds, &(elem(&1, 0) == kind)), do: kind, else: "comment"

    %{
      ref: issue.ref,
      issue: issue,
      kinds: kinds,
      kind: kind,
      body: "",
      body_error: nil,
      fixed_in: "",
      versions: Enum.map(socket.assigns.versions, & &1.number),
      error: nil
    }
  end

  # The resolutions the user may set on `issue` (D12).
  defp note_kinds(socket, review, issue) do
    %{perms: p, current_scope: scope} = socket.assigns
    mine? = review.reviewer_user_id == scope.user.id
    open? = unresolved?(issue)

    [{"comment", dgettext("ui", "评论")}] ++
      if(open? and p.write and not mine?,
        do: [{"accepted", dgettext("ui", "接受")}, {"disputed", dgettext("ui", "有异议")}],
        else: []
      ) ++
      if(open? and p.write and mine?, do: [{"withdrawn", dgettext("ui", "撤回")}], else: []) ++
      if(open? and p.rule,
        do: [{"upheld", dgettext("ui", "裁定：维持")}, {"dismissed", dgettext("ui", "裁定：驳回")}],
        else: []
      )
  end

  defp new_reason_panel(_socket, panel),
    do: %{
      kind: String.to_existing_atom(panel),
      reason: "",
      reason_error: nil,
      wake: true,
      error: nil
    }

  defp new_export_panel(socket) do
    v =
      (socket.assigns.version && socket.assigns.version.number) ||
        socket.assigns.spec.latest_version

    %{version: v, format: "tar.gz", reviews: false}
  end

  defp close_path(socket), do: Url.drop_params(socket.assigns.uri, ~w(panel issue kind))

  ## Events

  @impl true
  def handle_event("spec_start", _params, socket) do
    case SpecData.update(socket.assigns.current_scope, socket.assigns.ident, %{}) do
      {:ok, _} -> {:noreply, load(socket)}
      {:error, reason} -> {:noreply, error(socket, reason)}
    end
  end

  def handle_event("source_more", _params, socket),
    do: {:noreply, assign(socket, :source_limit, (socket.assigns.source_limit || 0) + @chunk)}

  def handle_event("diff_ends", %{"from" => from, "to" => to}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to: Url.put_params(socket.assigns.uri, %{tab: "diff", from: from, to: to})
       )}

  # 提交新版本 (D8)
  def handle_event("ver_submit", params, socket) do
    form = SpecVersionForm.change(socket.assigns.version_form, params["version"] || %{})
    %{current_scope: scope, ident: ident} = socket.assigns

    case SpecData.submit_version(scope, ident, SpecVersionForm.attrs(form)) do
      {:ok, %{version: n, validation: v}} ->
        {level, text} =
          if v.valid,
            do: {:info, dgettext("ui", "已提交 v%{n}", n: n)},
            else: {:warning, dgettext("ui", "已提交 v%{n}（校验未通过，定稿前需要修好）", n: n)}

        {:noreply,
         socket
         |> assign(version_form: nil, latest_seen: n)
         |> put_flash(level, text)
         |> push_patch(to: Url.drop_params(close_path(socket), ~w(v file line tab view)))}

      {:error, reason} ->
        socket = load(socket)
        form = SpecVersionForm.put_error(form, reason, stale_author(socket, reason))
        {:noreply, assign(socket, :version_form, form)}
    end
  end

  def handle_event("ver_rebase", _params, socket) do
    %{spec: spec, current_scope: scope, ident: ident} = socket.assigns
    latest = spec.latest_version

    form =
      SpecVersionForm.rebase(socket.assigns.version_form, latest, files_of(scope, ident, latest))

    {:noreply, assign(socket, :version_form, form)}
  end

  def handle_event("ver_" <> _ = event, params, %{assigns: %{version_form: %{}}} = socket),
    do: SpecVersionForm.handle_event(event, params, socket)

  # 写评审 (D9)
  def handle_event("rev_change", %{"review" => params}, socket),
    do: {:noreply, update_panel(socket, :review_form, &SpecReviewForm.change(&1, params))}

  def handle_event("rev_add_issue", _params, socket),
    do: {:noreply, update_panel(socket, :review_form, &SpecReviewForm.add_issue/1)}

  def handle_event("rev_remove", %{"index" => i}, socket),
    do:
      {:noreply,
       update_panel(socket, :review_form, &SpecReviewForm.remove_issue(&1, String.to_integer(i)))}

  def handle_event("rev_move", %{"index" => i, "dir" => dir}, socket),
    do:
      {:noreply,
       update_panel(socket, :review_form, &SpecReviewForm.move(&1, String.to_integer(i), dir))}

  def handle_event("rev_retarget", _params, socket) do
    %{spec: spec, current_scope: scope, ident: ident} = socket.assigns
    files = scope |> files_of(ident, spec.latest_version) |> line_counts()

    {:noreply,
     update_panel(socket, :review_form, &SpecReviewForm.retarget(&1, spec.latest_version, files))}
  end

  def handle_event("rev_submit", params, socket) do
    form = SpecReviewForm.change(socket.assigns.review_form, params["review"] || %{})

    cond do
      form.verdict == nil ->
        {:noreply, assign(socket, :review_form, %{form | error: dgettext("ui", "选择结论")})}

      not SpecReviewForm.valid?(form) ->
        {:noreply, assign(socket, :review_form, form)}

      true ->
        submit_review(socket, form)
    end
  end

  # 回复 (D9)
  def handle_event("note_change", %{"note" => params}, socket) do
    {:noreply,
     update_panel(socket, :note_panel, fn p ->
       p = note_params(p, params)
       %{p | body_error: if(p.body == "", do: nil, else: SpecPanels.note_body_error(p))}
     end)}
  end

  def handle_event("note_submit", params, socket) do
    params = params["note"] || %{}
    p = note_params(socket.assigns.note_panel, params)

    case SpecPanels.note_body_error(p) do
      nil -> submit_note(socket, p)
      text -> {:noreply, assign(socket, :note_panel, %{p | body_error: text})}
    end
  end

  # 请求评审 (D10)
  def handle_event("request_change", %{"request" => params}, socket) do
    {:noreply,
     update_panel(socket, :request_panel, fn p ->
       %{
         p
         | selected: Enum.reject(params["reviewers"] || [], &(&1 == "")),
           note: params["note"] || p.note
       }
     end)}
  end

  def handle_event("request_submit", params, socket) do
    params = params["request"] || %{}
    names = Enum.reject(params["reviewers"] || [], &(&1 == ""))
    p = %{socket.assigns.request_panel | selected: names, note: params["note"] || ""}
    %{current_scope: scope, ident: ident} = socket.assigns

    case SpecData.request_reviews(scope, ident, names, %{note: p.note}) do
      {:ok, %{requests: results}} ->
        texts = Enum.map(results, &SpecErrors.request_text/1)
        level = if Enum.any?(texts, &(elem(&1, 0) == :warning)), do: :warning, else: :info

        {:noreply,
         socket
         |> assign(:request_panel, nil)
         |> put_flash(level, Enum.map_join(texts, "；", &elem(&1, 1)))
         |> push_patch(to: close_path(socket))}

      {:error, reason} ->
        {:noreply,
         socket |> load() |> assign(:request_panel, %{p | error: SpecErrors.message(reason)})}
    end
  end

  def handle_event("ask_cancel", %{"n" => n}, socket) do
    case Enum.find(socket.assigns.spec.pending_reviews, &(to_string(&1.n) == n)) do
      nil -> {:noreply, socket}
      request -> {:noreply, assign(socket, :confirm_cancel, request)}
    end
  end

  def handle_event("dismiss_cancel", _params, socket),
    do: {:noreply, assign(socket, :confirm_cancel, nil)}

  def handle_event("cancel_request", _params, %{assigns: %{confirm_cancel: %{n: n}}} = socket) do
    %{current_scope: scope, ident: ident} = socket.assigns
    socket = assign(socket, :confirm_cancel, nil)

    case SpecData.cancel_request(scope, ident, %{request: n}) do
      {:ok, %{reviewer: name}} ->
        {:noreply,
         socket |> load() |> put_flash(:info, dgettext("ui", "已取消 %{name} 的评审请求", name: name))}

      {:error, reason} ->
        {:noreply, error(socket, reason)}
    end
  end

  def handle_event("cancel_request", _params, socket), do: {:noreply, socket}

  # 定稿 / 批准 (D10)
  def handle_event("finalize_change", %{"finalize" => params}, socket) do
    {:noreply,
     update_panel(
       socket,
       :finalize_panel,
       &%{&1 | summary: params["summary"] || &1.summary, wake: params["wake"] != "false"}
     )}
  end

  def handle_event("finalize_submit", params, socket) do
    params = params["finalize"] || %{}

    p = %{
      socket.assigns.finalize_panel
      | summary: params["summary"] || "",
        wake: params["wake"] != "false"
    }

    submit_finalize(socket, p)
  end

  # 退回 / 放弃 / 重新打开 (D10)
  def handle_event("reason_change", %{"reason" => params}, socket) do
    {:noreply,
     update_panel(socket, :reason_panel, fn p ->
       p = %{p | reason: params["reason"] || p.reason, wake: params["wake"] != "false"}
       %{p | reason_error: if(p.reason == "", do: nil, else: SpecPanels.reason_error(p))}
     end)}
  end

  def handle_event("reason_submit", params, socket) do
    params = params["reason"] || %{}

    p = %{
      socket.assigns.reason_panel
      | reason: params["reason"] || "",
        wake: params["wake"] != "false"
    }

    case SpecPanels.reason_error(p) do
      nil -> submit_reason(socket, p)
      text -> {:noreply, assign(socket, :reason_panel, %{p | reason_error: text})}
    end
  end

  # change_id (D10)
  def handle_event("change_id_change", %{"change_id" => %{"value" => value}}, socket),
    do:
      {:noreply,
       assign(socket, :change_id_panel, %{value: value, error: SpecPanels.change_id_error(value)})}

  def handle_event("change_id_submit", %{"change_id" => %{"value" => value}}, socket) do
    with nil <- SpecPanels.change_id_error(value),
         {:ok, _} <-
           SpecData.update(socket.assigns.current_scope, socket.assigns.ident, %{change_id: value}) do
      {:noreply,
       socket
       |> assign(:change_id_panel, nil)
       |> put_flash(:info, dgettext("ui", "change_id 已改为 %{id}", id: value))
       |> push_patch(to: close_path(socket))}
    else
      text when is_binary(text) ->
        {:noreply, assign(socket, :change_id_panel, %{value: value, error: text})}

      {:error, reason} ->
        {:noreply,
         assign(socket, :change_id_panel, %{value: value, error: SpecErrors.message(reason)})}
    end
  end

  # 导出 / 导入 (D11)
  def handle_event("export_change", %{"export" => params}, socket) do
    {:noreply,
     update_panel(socket, :export_panel, fn p ->
       %{
         p
         | version: int(params["version"] || "") || p.version,
           format: if(params["format"] in ~w(tar.gz zip), do: params["format"], else: p.format),
           reviews: params["reviews"] == "true"
       }
     end)}
  end

  def handle_event("import_change", params, socket) do
    note = get_in(params, ["import", "note"])
    {:noreply, update_panel(socket, :import_panel, &if(note, do: %{&1 | note: note}, else: &1))}
  end

  def handle_event("import_preview", _params, socket), do: {:noreply, preview_import(socket)}
  def handle_event("import_validate", _params, socket), do: {:noreply, socket}

  def handle_event("import_submit", params, socket) do
    p = socket.assigns.import_panel
    note = get_in(params, ["import", "note"]) || p.note
    %{current_scope: scope, ident: ident} = socket.assigns

    case SpecData.import_archive(scope, ident, p.binary,
           base_version: p.preview.base_version,
           note: note
         ) do
      {:ok, %{version: n}} ->
        {:noreply,
         socket
         |> assign(import_panel: nil, latest_seen: n)
         |> put_flash(:info, dgettext("ui", "已导入为 v%{n}", n: n))
         |> push_patch(to: Url.drop_params(close_path(socket), ~w(v file line)))}

      {:error, {:spec, :stale_version, latest}} ->
        {:noreply, assign(socket, :import_panel, %{p | stale: latest, preview: nil, note: note})}

      {:error, reason} ->
        {:noreply,
         assign(socket, :import_panel, %{p | error: SpecErrors.message(reason), note: note})}
    end
  end

  defp update_panel(socket, key, fun) do
    case socket.assigns[key] do
      nil -> socket
      value -> assign(socket, key, fun.(value))
    end
  end

  defp stale_author(socket, {:spec, :stale_version, n}), do: author_of(socket, n)
  defp stale_author(_socket, _reason), do: nil

  defp submit_review(socket, form) do
    %{current_scope: scope, ident: ident} = socket.assigns

    case SpecData.submit_review(scope, ident, SpecReviewForm.attrs(form)) do
      {:ok, %{review: n, dispatch: dispatch}} ->
        to =
          Url.put_params(Url.drop_params(close_path(socket), ~w(file line reviews view)), %{
            tab: "reviews"
          })

        {:noreply,
         socket
         |> assign(:review_form, nil)
         |> flash_with_wake(dgettext("ui", "已提交 R%{n}", n: n), dispatch)
         |> push_patch(to: to)}

      {:error, reason} ->
        {:noreply,
         socket |> load() |> assign(:review_form, SpecReviewForm.put_error(form, reason))}
    end
  end

  defp note_params(p, params),
    do: %{
      p
      | kind: params["kind"] || p.kind,
        body: params["body"] || p.body,
        fixed_in: params["fixed_in"] || p.fixed_in
    }

  defp submit_note(socket, p) do
    attrs = %{
      resolution: if(p.kind == "comment", do: nil, else: p.kind),
      body: p.body,
      fixed_in_version: if(p.kind == "accepted", do: int(p.fixed_in))
    }

    case SpecData.add_note(socket.assigns.current_scope, socket.assigns.ident, p.ref, attrs) do
      {:ok, _} ->
        {:noreply, socket |> assign(:note_panel, nil) |> push_patch(to: close_path(socket))}

      {:error, {:spec, :issue_resolved, _, _} = reason} ->
        p = %{
          p
          | kind: "comment",
            kinds: [{"comment", dgettext("ui", "评论")}],
            error: SpecErrors.message(reason)
        }

        {:noreply, socket |> load() |> assign(:note_panel, p)}

      {:error, reason} ->
        {:noreply,
         socket |> load() |> assign(:note_panel, %{p | error: SpecErrors.message(reason)})}
    end
  end

  defp submit_finalize(socket, p) do
    %{current_scope: scope, ident: ident, spec: spec} = socket.assigns
    wake = p.wake and wake_target(socket) != nil
    attrs = %{version: spec.latest_version, wake: wake}
    attrs = if p.summary == "", do: attrs, else: Map.put(attrs, :summary, p.summary)

    case SpecData.finalize(scope, ident, attrs) do
      {:ok, %{decision: decision, dispatch: dispatch, spec: new}} ->
        text =
          if decision == :approved,
            do: dgettext("ui", "已批准 v%{n}", n: new.final_version),
            else: dgettext("ui", "已定稿于 v%{n}", n: new.final_version)

        {:noreply,
         socket
         |> assign(:finalize_panel, nil)
         |> flash_with_wake(text, wake && dispatch)
         |> push_patch(to: close_path(socket))}

      {:error, reason} ->
        {:noreply,
         socket |> load() |> assign(:finalize_panel, %{p | error: SpecErrors.message(reason)})}
    end
  end

  defp submit_reason(socket, %{kind: kind} = p) do
    wake = kind == :reject and p.wake and wake_target(socket) != nil

    case reason_call(socket, p, wake) do
      {:ok, value} ->
        {:noreply,
         socket
         |> assign(:reason_panel, nil)
         |> flash_with_wake(reason_done(kind), wake && Map.get(value, :dispatch))
         |> push_patch(to: close_path(socket))}

      {:error, reason} ->
        {:noreply,
         socket |> load() |> assign(:reason_panel, %{p | error: SpecErrors.message(reason)})}
    end
  end

  defp reason_call(
         %{assigns: %{current_scope: scope, ident: ident}},
         %{kind: kind, reason: reason},
         wake
       ) do
    case kind do
      :reject -> SpecData.reject(scope, ident, %{reason: reason, wake: wake})
      :abandon -> SpecData.abandon(scope, ident, %{reason: reason})
      :reopen -> SpecData.reopen(scope, ident, %{reason: reason})
    end
  end

  defp reason_done(:reject), do: dgettext("ui", "已退回定稿提议")
  defp reason_done(:abandon), do: dgettext("ui", "已放弃规格")
  defp reason_done(:reopen), do: dgettext("ui", "已重新打开规格")

  defp flash_with_wake(socket, text, dispatch) do
    case SpecErrors.wake_text(dispatch) do
      nil -> put_flash(socket, :info, text)
      {level, wake} -> put_flash(socket, level, "#{text}；#{wake}")
    end
  end

  defp error(socket, reason),
    do: socket |> load() |> put_flash(:error, SpecErrors.message(reason))

  ## Uploads (D11)

  defp handle_progress(:spec_archive, entry, socket) do
    if entry.done? do
      {binary, name} =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, {File.read!(path), entry.client_name}}
        end)

      {:noreply,
       socket
       |> update_panel(
         :import_panel,
         &%{&1 | binary: binary, name: name, preview: nil, error: nil, stale: nil}
       )
       |> preview_import()}
    else
      {:noreply, socket}
    end
  end

  defp preview_import(%{assigns: %{import_panel: %{binary: binary} = p}} = socket)
       when is_binary(binary) do
    %{current_scope: scope, ident: ident, spec: spec} = socket.assigns
    base = (spec && spec.latest_version) || 0

    case SpecData.import_archive(scope, ident, binary, base_version: base, dry_run: true) do
      {:ok, preview} ->
        assign(socket, :import_panel, %{p | preview: preview, error: nil, stale: nil})

      {:error, reason} ->
        assign(socket, :import_panel, %{
          p
          | preview: nil,
            stale: nil,
            error: SpecErrors.message(reason)
        })
    end
  end

  defp preview_import(socket), do: socket

  ## Async and realtime

  @impl true
  def handle_async(:spec_diff, {:ok, result}, socket) do
    case {socket.assigns.diff, result} do
      {%{} = d, {:ok, diff}} ->
        {:noreply, assign(socket, :diff, %{d | result: diff})}

      {%{} = d, {:error, reason}} ->
        {:noreply, assign(socket, :diff, %{d | error: SpecErrors.message(reason)})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_async(:spec_diff, {:exit, _reason}, socket),
    do: {:noreply, update_panel(socket, :diff, &%{&1 | error: dgettext("ui", "对比失败，请重试")})}

  @impl true
  def handle_info({:spec_changed, _task_id}, socket), do: {:noreply, load(socket)}

  def handle_info({event, _payload}, socket) when event in [:task_updated, :task_transitioned] do
    case fetch_task(socket.assigns.current_scope, socket.assigns.ident) do
      nil -> {:noreply, socket}
      task -> {:noreply, assign(socket, :task, task)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Derived for rendering

  # Whom 通知执行方继续 wakes: the squad's leader or the managed agent of a task that is
  # new or in progress; nil otherwise (D10).
  defp wake_target(%{assigns: %{task: task}} = socket) do
    if task.status in ["new", "in_progress"], do: wake_text(socket, task.assignee)
  end

  defp wake_text(_socket, %{kind: "squad", name: name}),
    do: dgettext("ui", "唤醒 %{squad} 的 leader", squad: name)

  defp wake_text(socket, %{kind: "agent", name: name}),
    do: if(managed?(socket, name), do: dgettext("ui", "唤醒 %{agent}", agent: name))

  defp wake_text(_socket, _assignee), do: nil

  defp managed?(socket, name),
    do: match?(%{managed?: true}, TaskData.agent_info(socket.assigns.current_scope)[name])

  defp candidates(socket) do
    %{current_scope: scope, spec: spec, versions: versions} = socket.assigns
    author = Enum.find_value(versions, &(&1.number == spec.latest_version && &1.author))
    pending = for r <- spec.pending_reviews, r.version == spec.latest_version, do: r.reviewer
    availability = availability(scope)

    scope
    |> TaskData.assignable()
    |> Enum.filter(&(&1.kind in ["human", "agent"]))
    |> Enum.map(fn a ->
      %{
        name: a.name,
        dom: String.replace(a.name, ~r/[^A-Za-z0-9_-]/, "_"),
        kind_label: kind_label(a),
        author: a.name == author,
        pending: a.name in pending,
        unavailable: a[:managed?] && TaskData.unavailable_text(a.name, availability[a.name])
      }
    end)
  end

  defp availability(scope) do
    case HelmsmanWeb.RunData.availability(scope) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp kind_label(%{kind: "human"}), do: dgettext("ui", "人")
  defp kind_label(%{managed?: true}), do: dgettext("ui", "托管 Agent")
  defp kind_label(_), do: dgettext("ui", "外接 Agent")

  defp issue_actions(assigns, review) do
    %{perms: p, current_scope: scope} = assigns
    mine? = review.reviewer_user_id == scope.user.id

    fn issue ->
      if unresolved?(issue) do
        []
        |> add_action(p.write and not mine?, {"reply", dgettext("ui", "回复")})
        |> add_action(p.write and mine?, {"withdraw", dgettext("ui", "撤回")})
        |> add_action(p.rule, {"rule", dgettext("ui", "裁定")})
        |> add_action(p.write, {"comment", dgettext("ui", "评论")})
      else
        add_action([], p.write, {"comment", dgettext("ui", "评论")})
      end
    end
  end

  defp add_action(list, true, item), do: list ++ [item]
  defp add_action(list, _false, _item), do: list

  defp previous_final(versions, latest) do
    versions
    |> Enum.filter(&(&1.finalized != [] and &1.number < latest))
    |> Enum.map(& &1.number)
    |> Enum.max(fn -> max(latest - 1, 0) end)
  end

  defp action_items(assigns) do
    %{spec: spec, perms: p, uri: uri} = assigns
    archives? = SpecData.archives?()
    patch = &Url.put_params(uri, %{panel: &1})

    [
      p.write &&
        %{
          id: "spec-action-change-id",
          label: dgettext("ui", "修改 change_id"),
          icon: "lucide-pencil",
          patch: patch.("change-id")
        },
      (spec.latest_version > 0 and archives?) &&
        %{
          id: "spec-action-export",
          label: dgettext("ui", "导出"),
          icon: "lucide-download",
          patch: patch.("export")
        },
      (p.write and archives?) &&
        %{
          id: "spec-action-import",
          label: dgettext("ui", "导入 OpenSpec 目录"),
          icon: "lucide-upload",
          patch: patch.("import")
        },
      p.abandon &&
        %{
          id: "spec-action-abandon",
          label: dgettext("ui", "放弃"),
          icon: "lucide-archive-x",
          danger: true,
          patch: patch.("abandon")
        },
      p.reopen &&
        %{
          id: "spec-action-reopen",
          label: dgettext("ui", "重新打开"),
          icon: "lucide-rotate-ccw",
          patch: patch.("reopen")
        }
    ]
    |> Enum.filter(& &1)
  end

  ## Rendering

  @impl true
  def render(assigns) do
    spec = assigns.spec
    params = assigns.params
    uri = assigns.uri || ""
    drop = &Url.drop_params(uri, &1)

    assigns =
      assign(assigns,
        tab: tab(params),
        view: if(params["line"] || params["view"] == "source", do: "source", else: "rendered"),
        line: int(params["line"] || ""),
        follow: requested_version(params) == nil,
        issue_path:
          &Url.put_params(drop.(~w(panel issue kind)), %{tab: "reviews", highlight: &1}),
        items: if(spec, do: action_items(assigns), else: []),
        panel_close: drop.(~w(panel)),
        upload: get_in(assigns, [:uploads, :spec_archive]),
        gate:
          if(spec && spec.status not in [:finalized, :abandoned] && spec.latest_version > 0,
            do:
              gate_items(
                spec,
                assigns.refs,
                &Url.put_params(drop.(~w(panel)), %{tab: "reviews", highlight: &1})
              ),
            else: []
          )
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={dgettext("ui", "规格")}>
          <:crumb navigate={"/w/#{@slug}/t/#{@ident}"}>{@ident} {@task.title}</:crumb>
          <:actions>
            <.spec_status_badge :if={@spec} status={@spec.status} id="spec-status" />
            <code :if={@spec} id="spec-change-id" class="font-mono text-caption text-fg-muted">{@spec.change_id}</code>
            <.button
              :if={@spec && @perms.write}
              id="spec-new-version"
              size="sm"
              icon="lucide-file-pen"
              patch={Url.put_params(@uri, %{panel: "version"})}
            >
              {dgettext("ui", "提交新版本")}
            </.button>
            <.button
              :if={
                @spec && @spec.latest_version > 0 && @perms.write &&
                  @spec.status in [:draft, :in_review, :pending_approval]
              }
              id="spec-write-review"
              size="sm"
              icon="lucide-message-square-plus"
              patch={Url.put_params(@uri, %{panel: "review"})}
            >
              {dgettext("ui", "写评审")}
            </.button>
            <.button
              :if={@spec && @perms.approve}
              id="spec-finalize"
              size="sm"
              variant="primary"
              icon="lucide-badge-check"
              patch={Url.put_params(@uri, %{panel: "finalize"})}
            >
              {if @spec.proposal, do: dgettext("ui", "批准"), else: dgettext("ui", "定稿")}
            </.button>
            <.dropdown
              :if={@items != []}
              id="spec-more"
              items={@items}
              label={dgettext("ui", "更多操作")}
              align={:end}
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
          </:actions>
        </.page_header>
      </:header>

      <div class="flex flex-col gap-4 px-4 py-4 lg:px-6">
        <.banners
          :if={@spec}
          spec={@spec}
          perms={@perms}
          version={@version}
          follow={@follow}
          uri={@uri}
          scope={@current_scope}
        />

        <div :if={@spec == nil or @spec.latest_version == 0} id="spec-empty">
          <.empty_state
            icon="lucide-file-text"
            title={dgettext("ui", "%{ident} 还没有规格", ident: @ident)}
            description={
              if @spec,
                do: dgettext("ui", "已建立空规格，提交第一版开始起草。"),
                else: dgettext("ui", "先写规格、再实现：起草、评审、修订，定稿后再照常实现。")
            }
          >
            <:action :if={@perms.write}>
              <div class="flex flex-wrap justify-center gap-2">
                <.button :if={@spec == nil} id="spec-empty-start" phx-click="spec_start">{dgettext(
                  "ui",
                  "开始规格"
                )}</.button>
                <.button
                  id="spec-empty-draft"
                  variant="primary"
                  patch={Url.put_params(@uri, %{panel: "version"})}
                >
                  {dgettext("ui", "起草第一版")}
                </.button>
                <.button
                  :if={SpecData.archives?()}
                  id="spec-empty-import"
                  patch={Url.put_params(@uri, %{panel: "import"})}
                >
                  {dgettext("ui", "导入 OpenSpec 目录")}
                </.button>
              </div>
            </:action>
          </.empty_state>
        </div>

        <div
          :if={@spec && @spec.latest_version > 0}
          class="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr)_18rem]"
        >
          <div class="flex min-w-0 flex-col gap-4">
            <.tabs label={dgettext("ui", "规格")}>
              <:tab
                :for={{t, label} <- tabs()}
                patch={Url.put_params(Url.drop_params(@uri, ~w(panel line highlight)), %{tab: t})}
                active={@tab == t}
              >
                {label}
              </:tab>
            </.tabs>
            <.files_tab :if={@tab == "files"} {assigns} />
            <.diff_tab :if={@tab == "diff"} diff={@diff} versions={@versions} uri={@uri} />
            <.reviews_tab :if={@tab == "reviews"} {assigns} />
            <.history_tab :if={@tab == "history"} events={@events || []} />
          </div>
          <aside class="flex min-w-0 flex-col gap-6" aria-label={dgettext("ui", "规格属性")}>
            <.versions_list versions={@versions} current={@version && @version.number} uri={@uri} />
            <.pending_list spec={@spec} perms={@perms} uri={@uri} />
            <section :if={@gate != []} aria-labelledby="spec-gate-title" class="flex flex-col gap-2">
              <h2 id="spec-gate-title" class="text-label font-medium text-fg-muted">
                {dgettext("ui", "定稿门槛")}
              </h2>
              <.gate gate={@gate} />
              <p id="spec-mode" class="text-caption text-fg-muted">
                {dgettext("ui", "定稿方式：%{mode}", mode: mode_text(@spec, @task))}
              </p>
            </section>
          </aside>
        </div>
      </div>

      <SpecVersionForm.panel
        form={@version_form}
        scope={@current_scope}
        close_path={@panel_close}
        diff_path={&spec_path(@slug, @ident, %{tab: "diff", from: &1, to: &2})}
        closed={@spec != nil and @spec.status in [:finalized, :abandoned]}
      />
      <SpecReviewForm.panel
        form={@review_form}
        close_path={@panel_close}
        own={@review_form != nil and own_version?(@versions, @review_form.version, @current_scope)}
      />
      <SpecPanels.request
        panel={@request_panel}
        candidates={if(@request_panel, do: candidates(%{assigns: assigns}), else: [])}
        close_path={@panel_close}
        blocked={if(@spec && @spec.status == :pending_approval, do: dgettext("ui", "待批准期间不能请求评审"))}
      />
      <SpecPanels.note
        panel={@note_panel}
        scope={@current_scope}
        close_path={Url.drop_params(@uri || "", ~w(panel issue kind))}
      />
      <SpecPanels.finalize
        panel={@finalize_panel}
        spec={@spec}
        gate={@gate}
        wake_target={if(@finalize_panel, do: wake_target(%{assigns: assigns}))}
        diff_path={finalize_diff_path(@spec, @versions, @panel_close)}
        scope={@current_scope}
        close_path={@panel_close}
      />
      <SpecPanels.reason
        panel={@reason_panel}
        wake_target={if(@reason_panel, do: wake_target(%{assigns: assigns}))}
        close_path={@panel_close}
      />
      <SpecPanels.change_id panel={@change_id_panel} close_path={@panel_close} />
      <SpecPanels.export
        panel={@export_panel}
        versions={@versions}
        href={@export_panel && export_href(@slug, @ident, @export_panel)}
        close_path={@panel_close}
      />
      <SpecPanels.import panel={@import_panel} upload={@upload} close_path={@panel_close} />
      <%!-- Outside the panel's portal so the panel's label can open it and tests can
           reach it (the pattern of SettingsLive.Data). --%>
      <form
        :if={@upload}
        id="spec-import-upload-form"
        phx-change="import_validate"
        class="sr-only"
        aria-hidden="true"
      >
        <.live_file_input upload={@upload} tabindex="-1" />
      </form>
      <.confirm_dialog
        id="spec-cancel-request"
        show={@confirm_cancel != nil}
        title={
          if(@confirm_cancel,
            do: dgettext("ui", "取消 %{name} 的评审请求？", name: @confirm_cancel.reviewer),
            else: ""
          )
        }
        confirm_label={dgettext("ui", "取消请求")}
        cancel_label={dgettext("ui", "保留")}
        danger
        on_confirm="cancel_request"
        on_cancel={JS.push("dismiss_cancel")}
      >
        {dgettext("ui", "请求取消后不再挡住定稿；评审人已开始的运行在领取前会被丢弃。")}
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  defp export_href(slug, ident, p),
    do:
      "/w/#{slug}/t/#{ident}/spec/export?" <>
        URI.encode_query(%{version: p.version, format: p.format, reviews: p.reviews})

  defp finalize_diff_path(%{latest_version: latest}, versions, base) when latest > 1,
    do: Url.put_params(base, %{tab: "diff", from: previous_final(versions, latest), to: latest})

  defp finalize_diff_path(_spec, _versions, _base), do: nil

  defp tabs,
    do: [
      {"files", dgettext("ui", "文件")},
      {"diff", dgettext("ui", "对比")},
      {"reviews", dgettext("ui", "评审")},
      {"history", dgettext("ui", "历史")}
    ]

  defp own_version?(versions, n, scope),
    do: Enum.any?(versions, &(&1.number == n and &1.author == scope.actor.name))

  defp mode_text(%{mode: :leader}, %{assignee: %{kind: "squad", name: name}}),
    do: dgettext("ui", "Leader 定稿（%{squad}）", squad: name)

  defp mode_text(spec, _task), do: mode_label(spec.mode)

  ## Banners (D3)

  attr :spec, :map, required: true
  attr :perms, :map, required: true
  attr :version, :map, default: nil
  attr :follow, :boolean, required: true
  attr :uri, :string, required: true
  attr :scope, :map, required: true

  defp banners(assigns) do
    ~H"""
    <div
      :if={@spec.proposal}
      id="spec-banner-proposal"
      role="status"
      class="flex flex-col gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="flex-1">
          {dgettext("ui", "%{by} 提议以 v%{v} 定稿", by: @spec.proposal.by, v: @spec.proposal.version)}
        </span>
        <.button
          :if={@perms.approve}
          id="spec-banner-approve"
          size="xs"
          variant="primary"
          patch={Url.put_params(@uri, %{panel: "finalize"})}
        >
          {dgettext("ui", "批准")}
        </.button>
        <.button
          :if={@perms.reject}
          id="spec-banner-reject"
          size="xs"
          patch={Url.put_params(@uri, %{panel: "reject"})}
        >
          {dgettext("ui", "退回")}
        </.button>
      </div>
      <details
        :if={@spec.proposal.summary}
        open={byte_size(@spec.proposal.summary) <= 1024}
        class="text-fg"
      >
        <summary class="cursor-pointer text-caption text-fg-muted">{dgettext("ui", "汇总")}</summary>
        <.markdown content={@spec.proposal.summary} scope={@scope} anchor_ns="spec-proposal" />
      </details>
    </div>
    <div
      :if={@spec.status == :finalized}
      id="spec-banner-final"
      role="status"
      class="flex items-center gap-2 rounded-field border border-border tint-success px-3 py-2 text-body text-success-fg"
    >
      <span class="flex-1">{dgettext("ui", "已定稿于 v%{v}", v: @spec.final_version)}</span>
      <.link
        :if={@version && @version.number != @spec.final_version}
        id="spec-banner-final-link"
        patch={
          Url.put_params(Url.drop_params(@uri, ~w(line)), %{v: @spec.final_version, tab: "files"})
        }
        class="hover:underline"
      >
        {dgettext("ui", "查看定稿版本")}
      </.link>
    </div>
    <div
      :if={@spec.status == :abandoned}
      id="spec-banner-abandoned"
      role="status"
      class="rounded-field border border-border bg-surface px-3 py-2 text-body text-fg-muted"
    >
      {dgettext("ui", "已放弃")}
    </div>
    <div
      :if={(!@follow and @version) && @version.number != @spec.latest_version}
      id="spec-banner-old"
      role="status"
      class="flex items-center gap-2 rounded-field border border-border bg-surface px-3 py-2 text-body text-fg-muted"
    >
      <span class="flex-1">
        {dgettext("ui", "你在看 v%{v}，最新是 v%{latest}", v: @version.number, latest: @spec.latest_version)}
      </span>
      <.link id="spec-banner-latest" patch={Url.drop_params(@uri, ~w(v line))} class="hover:underline">{dgettext(
        "ui",
        "看最新"
      )}</.link>
    </div>
    """
  end

  ## Files tab (D5)

  defp files_tab(assigns) do
    %{version: version, spec: spec, perms: perms, uri: uri, file: file} = assigns
    paths = SpecVersionForm.sort_paths(Enum.map(version.files, & &1.path))
    latest? = version.number == spec.latest_version
    open? = spec.status in [:draft, :in_review, :pending_approval]

    assigns =
      assign(assigns,
        paths: paths,
        bytes_of: Map.new(version.files, &{&1.path, &1.bytes}),
        invalid: MapSet.new(version.validation.errors, & &1.file),
        file_markers:
          for({{f, line}, issues} <- assigns.markers, f == file, into: %{}, do: {line, issues}),
        add_path:
          if(perms.write and latest? and open?,
            do: &Url.put_params(uri, %{panel: "review", file: file, line: &1, view: "source"}),
            else: nil
          ),
        file_path: &Url.put_params(Url.drop_params(uri, ~w(line)), %{file: &1})
      )

    ~H"""
    <div class="grid grid-cols-1 gap-4 md:grid-cols-[14rem_minmax(0,1fr)]">
      <nav id="spec-files" aria-label={dgettext("ui", "文件")} class="flex flex-col gap-0.5">
        <.link
          :for={path <- @paths}
          id={"spec-file-" <> String.replace(path, ~r/[^a-z0-9]/, "-")}
          patch={@file_path.(path)}
          data-path={path}
          aria-current={path == @file && "page"}
          class={[
            "flex items-center gap-1.5 rounded-field px-2 py-1 text-body",
            if(path == @file, do: "bg-hover text-fg", else: "text-fg-muted hover:bg-hover")
          ]}
        >
          <span class="min-w-0 flex-1 truncate font-mono text-caption">{path}</span>
          <span :if={MapSet.member?(@invalid, path)} class="text-danger" data-invalid>✗</span>
          <span
            :if={@file_counts[path]}
            class="rounded-badge tint-warning px-1 text-micro text-warning-fg"
            data-unresolved
          >
            {@file_counts[path]}
          </span>
          <span class="text-micro text-fg-subtle">{bytes(@bytes_of[path])}</span>
        </.link>
      </nav>
      <div class="flex min-w-0 flex-col gap-3">
        <details
          id="spec-validation"
          open={!@version.validation.valid}
          class="rounded-field border border-border px-3 py-2 text-body"
        >
          <summary class={[
            "cursor-pointer",
            if(@version.validation.valid, do: "text-success-fg", else: "text-danger-fg")
          ]}>
            {if @version.validation.valid,
              do: dgettext("ui", "校验通过"),
              else: dgettext("ui", "%{n} 个问题", n: length(@version.validation.errors))}
          </summary>
          <ul class="mt-2 flex flex-col gap-1">
            <li :for={{e, k} <- Enum.with_index(@version.validation.errors)}>
              <.link
                id={"spec-validation-#{k}"}
                patch={
                  Url.put_params(
                    @uri,
                    Map.reject(%{file: e.file, line: e.line, view: "source"}, fn {_, v} ->
                      is_nil(v)
                    end)
                  )
                }
                class="font-mono text-caption text-danger-fg hover:underline"
              >
                {SpecErrors.validation_line(e)}
              </.link>
            </li>
          </ul>
        </details>
        <div :if={@file} class="flex items-center gap-2">
          <code class="flex-1 truncate font-mono text-body text-fg" id="spec-file-path">{@file}</code>
          <.link
            id="spec-view-rendered"
            patch={Url.put_params(Url.drop_params(@uri, ~w(line)), %{view: "rendered"})}
            class={[
              "rounded-field px-2 py-0.5 text-caption",
              if(@view == "rendered", do: "bg-hover text-fg", else: "text-fg-muted")
            ]}
          >
            {dgettext("ui", "渲染")}
          </.link>
          <.link
            id="spec-view-source"
            patch={Url.put_params(@uri, %{view: "source"})}
            class={[
              "rounded-field px-2 py-0.5 text-caption",
              if(@view == "source", do: "bg-hover text-fg", else: "text-fg-muted")
            ]}
          >
            {dgettext("ui", "源码")}
          </.link>
        </div>
        <div :if={@content && @view == "rendered"} id="spec-rendered">
          <.markdown
            content={@content}
            scope={@current_scope}
            anchor_ns={"spec-#{Enum.find_index(@paths, &(&1 == @file))}"}
          />
        </div>
        <.source_view
          :if={@content && @view == "source"}
          content={@content}
          line={@line}
          markers={@file_markers}
          add_path={@add_path}
          issue_path={@issue_path}
          limit={@source_limit}
        />
      </div>
    </div>
    """
  end

  defp bytes(nil), do: ""
  defp bytes(n) when n >= 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp bytes(n), do: "#{n} B"

  ## Diff tab (D6)

  attr :diff, :map, default: nil
  attr :versions, :list, required: true
  attr :uri, :string, required: true

  defp diff_tab(assigns) do
    latest = assigns.versions |> Enum.map(& &1.number) |> Enum.max(fn -> 0 end)

    final =
      assigns.versions
      |> Enum.filter(&(&1.finalized != []))
      |> Enum.map(& &1.number)
      |> Enum.max(fn -> nil end)

    assigns = assign(assigns, latest: latest, final: final)

    ~H"""
    <div class="flex flex-col gap-3">
      <form
        id="spec-diff-ends"
        phx-change="diff_ends"
        class="flex flex-wrap items-center gap-2 text-body"
      >
        <select
          name="from"
          id="spec-diff-from"
          class="rounded-field border border-border bg-surface px-2 py-1"
        >
          <option :for={n <- 0..@latest} value={n} selected={@diff && @diff.from == n}>
            {if n == 0, do: dgettext("ui", "（空）"), else: "v#{n}"}
          </option>
        </select>
        <span>→</span>
        <select
          name="to"
          id="spec-diff-to"
          class="rounded-field border border-border bg-surface px-2 py-1"
        >
          <option :for={n <- 1..@latest} value={n} selected={@diff && @diff.to == n}>v{n}</option>
        </select>
        <.link
          :if={@final && @final != @latest}
          id="spec-diff-final"
          patch={Url.put_params(@uri, %{tab: "diff", from: @final, to: @latest})}
          class="text-caption text-fg-muted hover:underline"
        >
          {dgettext("ui", "对比上一定稿版本")}
        </.link>
      </form>
      <div :if={@diff && @diff.error} role="alert" class="text-body text-danger-fg">
        {@diff.error}
      </div>
      <div
        :if={@diff && !@diff.result && !@diff.error}
        id="spec-diff-loading"
        class="text-body text-fg-muted"
      >
        {dgettext("ui", "正在计算差异…")}
      </div>
      <.diff :if={@diff && @diff.result} result={@diff.result} />
    </div>
    """
  end

  ## Reviews tab (D7)

  defp reviews_tab(assigns) do
    uri = assigns.uri

    assigns =
      assign(assigns,
        filter: assigns.params["reviews"] || "all",
        filters: [
          {"all", dgettext("ui", "全部")},
          {"v#{assigns.spec.latest_version}", dgettext("ui", "当前版本")},
          {"unresolved", dgettext("ui", "只看未解决")}
        ],
        highlight: assigns.params["highlight"],
        note_path:
          &Url.put_params(Url.drop_params(uri, ~w(highlight)), %{
            panel: "note",
            issue: &1,
            kind: &2
          }),
        to_file: fn v, file, line ->
          params = %{tab: "files", v: v, file: file, view: "source"}
          params = if line, do: Map.put(params, :line, line), else: params
          Url.put_params(Url.drop_params(uri, ~w(panel highlight reviews)), params)
        end,
        actions: &issue_actions(assigns, &1)
      )

    ~H"""
    <div class="flex flex-col gap-4">
      <nav class="flex gap-2 text-caption" id="spec-reviews-filter">
        <.link
          :for={{value, label} <- @filters}
          id={"spec-reviews-filter-#{if(String.starts_with?(value, "v"), do: "version", else: value)}"}
          patch={
            Url.put_params(Url.drop_params(@uri, ~w(highlight)), %{tab: "reviews", reviews: value})
          }
          class={[
            "rounded-field px-2 py-0.5",
            if(@filter == value, do: "bg-hover text-fg", else: "text-fg-muted")
          ]}
        >
          {label}
        </.link>
      </nav>
      <section
        :if={@tab_reviews && @tab_reviews.requests != []}
        id="spec-requests"
        class="flex flex-col gap-1"
      >
        <h3 class="text-label font-medium text-fg-muted">{dgettext("ui", "评审请求")}</h3>
        <div
          :for={r <- @tab_reviews.requests}
          id={"spec-request-#{r.n}"}
          data-status={r.status}
          class="flex flex-wrap items-center gap-2 text-body"
        >
          <span class="text-fg">{r.reviewer}</span>
          <span class="text-caption text-fg-muted">v{r.version} · {r.requested_by}</span>
          <span class="text-caption" data-request-state>{request_label(r)}</span>
          <.button
            :if={r.status == :requested and can_cancel?(@perms, r, @current_scope)}
            id={"spec-request-#{r.n}-cancel"}
            size="xs"
            variant="ghost"
            phx-click="ask_cancel"
            phx-value-n={r.n}
          >
            {dgettext("ui", "取消")}
          </.button>
        </div>
      </section>
      <p
        :if={@tab_reviews && @tab_reviews.reviews == []}
        id="spec-reviews-empty"
        class="text-body text-fg-muted"
      >
        {dgettext("ui", "没有评审")}
      </p>
      <.review_card
        :for={review <- (@tab_reviews && @tab_reviews.reviews) || []}
        review={review}
        latest={@spec.latest_version}
        scope={@current_scope}
        actions={@actions.(review)}
        note_path={@note_path}
        file_path={@to_file}
        highlight={@highlight}
      />
    </div>
    """
  end

  defp can_cancel?(perms, request, scope),
    do: perms.request_review or perms.abandon or request.requested_by == scope.actor.name

  ## History tab

  attr :events, :list, required: true

  defp history_tab(assigns) do
    ~H"""
    <ol id="spec-history" class="flex flex-col divide-y divide-border">
      <li
        :for={e <- @events}
        id={"spec-event-#{e.n}"}
        data-action={e.action}
        class="flex flex-col gap-0.5 py-2 text-body"
      >
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-fg">{e.actor}</span>
          <span class="text-fg-muted" data-event-text>{event_text(e)}</span>
          <.relative_time id={"spec-event-#{e.n}-at"} at={e.at} class="text-caption text-fg-subtle" />
        </div>
        <p :if={event_detail(e)} class="whitespace-pre-wrap text-caption text-fg-muted" data-detail>
          {event_detail(e)}
        </p>
      </li>
    </ol>
    """
  end

  ## Right column

  attr :versions, :list, required: true
  attr :current, :integer, default: nil
  attr :uri, :string, required: true

  defp versions_list(assigns) do
    ~H"""
    <section aria-labelledby="spec-versions-title" class="flex flex-col gap-1">
      <h2 id="spec-versions-title" class="text-label font-medium text-fg-muted">
        {dgettext("ui", "版本")}
      </h2>
      <ol id="spec-versions" class="flex flex-col gap-0.5">
        <li :for={v <- Enum.reverse(@versions)}>
          <.link
            id={"spec-version-#{v.number}"}
            patch={
              Url.put_params(Url.drop_params(@uri, ~w(line panel)), %{v: v.number, tab: "files"})
            }
            class={[
              "flex flex-col rounded-field px-2 py-1 text-body",
              if(v.number == @current, do: "bg-hover", else: "hover:bg-hover")
            ]}
          >
            <span class="flex flex-wrap items-center gap-1.5">
              <span class="font-mono text-fg">v{v.number}</span>
              <span
                class={if(v.valid, do: "text-success", else: "text-danger")}
                data-valid={"#{v.valid}"}
              >
                {if v.valid, do: "✓", else: "✗"}
              </span>
              <span class="truncate text-caption text-fg-muted">{v.author}</span>
              <.badge :for={f <- v.finalized} tone={:success} data-finalized>
                {dgettext("ui", "定稿 · %{by}", by: f.by)}
              </.badge>
            </span>
            <span :if={v.note != ""} class="truncate text-caption text-fg-subtle">{first_line(v.note)}</span>
          </.link>
        </li>
      </ol>
    </section>
    """
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  attr :spec, :map, required: true
  attr :perms, :map, required: true
  attr :uri, :string, required: true

  defp pending_list(assigns) do
    assigns =
      assign(assigns,
        pending:
          for(r <- assigns.spec.pending_reviews, r.version == assigns.spec.latest_version, do: r),
        open: assigns.spec.status in [:draft, :in_review, :pending_approval]
      )

    ~H"""
    <section aria-labelledby="spec-pending-title" class="flex flex-col gap-1">
      <h2 id="spec-pending-title" class="text-label font-medium text-fg-muted">
        {dgettext("ui", "待完成的评审")}
      </h2>
      <p :if={@pending == []} class="text-caption text-fg-subtle">—</p>
      <div :for={r <- @pending} id={"spec-pending-#{r.n}"} class="flex items-center gap-2 text-body">
        <span class="text-fg">{r.reviewer}</span>
        <span class="flex-1 truncate text-caption text-fg-muted">{r.requested_by}</span>
        <.button
          :if={@perms.request_review or @perms.abandon}
          id={"spec-pending-#{r.n}-cancel"}
          size="xs"
          variant="ghost"
          phx-click="ask_cancel"
          phx-value-n={r.n}
        >
          {dgettext("ui", "取消")}
        </.button>
      </div>
      <div :if={@open and @perms.write}>
        <.button
          id="spec-request-review"
          size="xs"
          icon="lucide-user-plus"
          patch={Url.put_params(@uri, %{panel: "request"})}
          disabled={@spec.status == :pending_approval}
          disabled_reason={if(@spec.status == :pending_approval, do: dgettext("ui", "待批准期间不能请求评审"))}
        >
          {dgettext("ui", "请求评审")}
        </.button>
      </div>
    </section>
    """
  end
end
