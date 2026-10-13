defmodule HelmsmanWeb.ProjectGitHubForm do
  @moduledoc """
  The 仓库与合并 panel of a project (add-github-ui D6; spec web-github 项目的仓库与合并设置).
  The state is a plain map kept by `HelmsmanWeb.TaskLive.Index` (`?panel=project-github`);
  the page owns the events and the background tasks (branch suggestions, saving).

  * `base` holds the project's settings the panel diffs against; `attrs/1` submits only
    the changed keys, so an unchanged base branch is not checked on GitHub again.
  * Repository options: the workspace's available repositories, plus the bound one when
    it is unavailable (it may be kept, not chosen again).
  * Choosing another repository clears the base branch.
  * `mode` (add-local-repositories-ui D5): `:github` or `:local` (a repository on a
    daemon's machine, `local_attrs/1`, saved with `Helmsman.Projects.bind_local_repository/4`).
    A project bound in one mode cannot switch to the other in the panel (unbind and save
    first); an unbound one switches freely, which clears the other side's choice and
    the base branch. The local mode has no merge settings.
  """
  use HelmsmanWeb, :html

  alias Helmsman.{GitHub, LocalRepositories}
  alias Helmsman.Projects.Project
  alias HelmsmanWeb.{FormErrors, LocalRepositoryComponents}

  @keys [
    :repository_id,
    :base_branch,
    :merge_policy,
    :merge_method,
    :require_ci,
    :delete_branch_after_merge
  ]

  ## State

  @doc "A panel for `project` (as read by `Helmsman.Projects`)."
  def new(scope, %Project{} = project) do
    values = values(project)

    %{
      key: project.key,
      mode: mode(values) || :github,
      base: values,
      params: values,
      current: project.repository,
      current_local: project.local_repository,
      repositories: repositories(scope),
      locals: locals(scope),
      branches: [],
      errors: %{},
      alert: nil,
      saving?: false
    }
  end

  # The mode of bound settings; nil when bound to neither.
  defp mode(%{local_repository_id: id}) when id != nil, do: :local
  defp mode(%{repository_id: id}) when id != nil, do: :github
  defp mode(_values), do: nil

  defp values(project) do
    %{
      local_repository_id: project.local_repository_id,
      repository_id: project.repository_id,
      base_branch: project.base_branch || "",
      merge_policy: project.merge_policy,
      merge_method: project.merge_method,
      require_ci: project.require_ci,
      delete_branch_after_merge: project.delete_branch_after_merge
    }
  end

  defp repositories(scope) do
    case GitHub.status(scope) do
      {:ok, %{repositories: repositories}} -> repositories
      {:error, _} -> []
    end
  end

  defp locals(scope) do
    case LocalRepositories.list(scope) do
      {:ok, locals} -> locals
      {:error, _} -> []
    end
  end

  @doc "Reads the repository options again (`{:github_changed}`, a refused repository)."
  def reload_repositories(form, scope), do: %{form | repositories: repositories(scope)}

  @doc """
  Reads the local repository options again (`{:local_repositories_changed}`, a removed
  repository); the selection and the base branch stay.
  """
  def reload_locals(form, scope), do: %{form | locals: locals(scope)}

  @doc "Whether the panel may switch to `mode`: not while the base is bound in the other."
  def can_switch?(form, mode), do: mode(form.base) in [nil, mode]

  @doc """
  Switches the mode (D5) when allowed: the other side's choice and the base branch are
  cleared, the merge settings are kept.
  """
  def set_mode(form, mode) when mode in [:github, :local] do
    if mode == form.mode or not can_switch?(form, mode) do
      form
    else
      params = %{
        form.params
        | repository_id: form.base.repository_id,
          local_repository_id: form.base.local_repository_id,
          base_branch: ""
      }

      %{form | mode: mode, params: params, branches: [], errors: %{}}
    end
  end

  @doc "Selects the local repository `id` (nil = 不绑定); another one clears the base branch."
  def select_local(form, id) do
    if id == form.params.local_repository_id do
      form
    else
      params = %{form.params | local_repository_id: id, base_branch: ""}
      %{form | params: params, errors: Map.drop(form.errors, [:local_repository_id])}
    end
  end

  @doc """
  The project changed elsewhere while the panel is open and not saving: the base becomes
  the new settings; fields the user has not changed follow it, changed ones are kept.
  """
  def rebase(form, %Project{} = project) do
    fresh = values(project)
    mode = mode(fresh) || form.mode

    %{
      form
      | mode: mode,
        base: fresh,
        params: rebase_params(form, fresh, mode),
        current: project.repository,
        current_local: project.local_repository
    }
  end

  defp rebase_params(%{mode: mode} = form, fresh, mode) do
    Map.new([:local_repository_id | @keys], fn key ->
      if form.params[key] == form.base[key],
        do: {key, fresh[key]},
        else: {key, form.params[key]}
    end)
  end

  # Bound in the other mode elsewhere: this mode's choice cannot be saved.
  defp rebase_params(form, fresh, _mode),
    do:
      Map.merge(
        fresh,
        Map.drop(form.params, [:local_repository_id, :repository_id, :base_branch])
      )

  @doc """
  The local save was refused (`:repository_already_bound`) and `project` is the
  re-read one: the base becomes it, the mode follows it, the choice is reset to it.
  """
  def already_bound(form, %Project{} = project) do
    fresh = values(project)

    %{
      form
      | mode: mode(fresh) || form.mode,
        base: fresh,
        params: fresh,
        current: project.repository,
        current_local: project.local_repository,
        branches: [],
        saving?: false,
        alert: nil,
        errors: %{repository_id: [dgettext("ui", "项目已绑定 GitHub 仓库，先解除绑定")]}
    }
  end

  @doc """
  The save returned `:stale` and `project` is the re-read one: it becomes the base, and
  the repository and base branch are reset to it (they are what changed); the other
  edits are kept.
  """
  def stale(form, %Project{} = project) do
    fresh = values(project)

    params =
      Map.merge(form.params, Map.take(fresh, [:repository_id, :base_branch]))

    %{form | base: fresh, params: params, current: project.repository, branches: []}
  end

  @doc "Selects the repository `id` (nil = 不绑定); another repository clears the base branch."
  def select_repository(form, id) do
    if id == form.params.repository_id do
      form
    else
      params = %{form.params | repository_id: id, base_branch: ""}
      %{form | params: params, branches: [], errors: Map.drop(form.errors, [:repository_id])}
    end
  end

  @doc "Applies the form's `phx-change` params (fields absent from them keep their value)."
  def change(%{mode: :local} = form, params) when is_map(params) do
    old = form.params.local_repository_id
    form = select_local(form, parse_id(params, "local_repository_id", old))
    p = form.params

    base_branch =
      cond do
        p.local_repository_id != old -> ""
        p.local_repository_id == nil -> ""
        true -> Map.get(params, "base_branch", p.base_branch)
      end

    %{form | params: %{p | base_branch: base_branch}}
  end

  def change(form, params) when is_map(params) do
    old = form.params.repository_id
    form = select_repository(form, parse_id(params, "repository_id", old))
    p = form.params
    moved? = p.repository_id != old

    params = %{
      p
      | base_branch: if(moved?, do: "", else: Map.get(params, "base_branch", p.base_branch)),
        merge_policy: pick(params["merge_policy"], Project.merge_policies(), p.merge_policy),
        merge_method: pick(params["merge_method"], Project.merge_methods(), p.merge_method),
        require_ci: bool(params["require_ci"], p.require_ci),
        delete_branch_after_merge:
          bool(params["delete_branch_after_merge"], p.delete_branch_after_merge)
    }

    %{form | params: params}
  end

  defp parse_id(params, name, current) do
    case Map.fetch(params, name) do
      {:ok, ""} ->
        nil

      {:ok, value} when is_binary(value) ->
        case Integer.parse(value) do
          {id, ""} -> id
          _ -> current
        end

      _ ->
        current
    end
  end

  defp pick(value, allowed, current), do: if(value in allowed, do: value, else: current)

  defp bool("true", _current), do: true
  defp bool("false", _current), do: false
  defp bool(_value, current), do: current

  @doc "The changed settings, as `Helmsman.Projects.update_github_settings/3` takes them."
  def attrs(form) do
    for key <- @keys, form.params[key] != form.base[key], into: %{} do
      case {key, form.params[key]} do
        {:base_branch, ""} -> {key, nil}
        {:base_branch, branch} -> {key, String.trim(branch)}
        {key, value} -> {key, value}
      end
    end
  end

  @doc """
  The changed local settings (`:local_repository_id`, `:base_branch`; `""` = the
  default branch, nil). Unbinding clears the base branch on its own (decision 18).
  """
  def local_attrs(form) do
    for key <- [:local_repository_id, :base_branch],
        form.params[key] != form.base[key],
        into: %{} do
      case {key, form.params[key]} do
        {:base_branch, branch} -> {key, String.trim(branch || "")}
        {key, value} -> {key, value}
      end
    end
  end

  @doc """
  The arguments of `Helmsman.Projects.bind_local_repository/4`: `{id, opts}`, with
  `base_branch` in `opts` only when it changed (and a repository is chosen).
  """
  def local_binding(form) do
    attrs = local_attrs(form)
    id = form.params.local_repository_id

    opts =
      case attrs do
        %{base_branch: branch} when id != nil -> [base_branch: branch]
        _ -> []
      end

    {id, opts}
  end

  @doc "Whether the panel has unsaved changes."
  def dirty?(%{mode: :local} = form), do: local_changed?(form)
  def dirty?(form), do: attrs(form) != %{}

  # Unbinding clears the base branch: an edited branch alone is not a change then.
  defp local_changed?(form) do
    case local_attrs(form) do
      %{local_repository_id: _} -> true
      %{base_branch: _} -> form.params.local_repository_id != nil
      _ -> false
    end
  end

  @doc "Marks the save as running and clears the previous errors."
  def saving(form), do: %{form | saving?: true, errors: %{}, alert: nil}

  @doc """
  A failed save. Returns `{:form, form, reload_repositories?}` to keep the panel open, or
  `{:close, message}` (the panel closes with an error flash). `:stale` and a
  `:not_found` that may be the project itself need the page to re-read the project.
  """
  def errors(form, reason), do: error(%{form | saving?: false}, reason)

  defp error(form, {:branch_not_found, branch}),
    do: field(form, :base_branch, dgettext("ui", "GitHub 上没有分支 %{branch}", branch: branch))

  defp error(form, :repository_unavailable) do
    form
    |> field(:repository_id, dgettext("ui", "仓库不可用（安装已断开、已暂停或仓库已移出范围）"))
    |> reload()
  end

  defp error(form, :repository_required),
    do: field(form, :base_branch, dgettext("ui", "先选择仓库"))

  defp error(form, {kind, _detail}) when kind in [:github_unavailable, :rate_limited],
    do: alert(form, dgettext("ui", "暂时无法连接 GitHub，设置没有保存，请稍后重试"))

  defp error(form, :stale),
    do: alert(form, dgettext("ui", "仓库或基础分支刚被其他人修改，已载入最新设置，请确认后重新保存"))

  defp error(_form, :forbidden),
    do: {:close, dgettext("ui", "只有工作区的所有者或管理员可以修改仓库设置")}

  defp error(%{mode: :local} = form, :not_found) do
    {:form, form, _reload?} = field(form, :local_repository_id, dgettext("ui", "本地仓库已被移除"))
    {:form, form, true}
  end

  defp error(form, :not_found),
    do: form |> field(:repository_id, dgettext("ui", "仓库不存在")) |> reload()

  defp error(form, %Ecto.Changeset{} = changeset),
    do: {:form, %{form | errors: FormErrors.messages(changeset)}, false}

  defp error(form, _other), do: alert(form, dgettext("ui", "保存失败，请重试"))

  defp alert(form, message), do: {:form, %{form | alert: message}, false}

  defp field(form, key, message), do: {:form, %{form | errors: %{key => [message]}}, false}

  defp reload({:form, form, _reload?}), do: {:form, form, true}

  ## Rendering

  @doc "The repository options: `[%{id, full_name, private, available, default_branch}]`."
  def options(form) do
    available = Enum.filter(form.repositories, & &1.available)
    current_id = form.base.repository_id

    cond do
      current_id == nil or Enum.any?(available, &(&1.id == current_id)) ->
        available

      listed = Enum.find(form.repositories, &(&1.id == current_id)) ->
        [listed | available]

      form.current != nil ->
        [
          %{
            id: current_id,
            full_name: form.current.full_name,
            private: false,
            available: form.current.available,
            default_branch: nil
          }
          | available
        ]

      true ->
        available
    end
  end

  defp selected(form), do: Enum.find(options(form), &(&1.id == form.params.repository_id))

  attr :form, :map, required: true
  attr :project, :map, required: true
  attr :slug, :string, required: true
  attr :close_path, :string, required: true

  def panel(assigns) do
    form = assigns.form
    selected = selected(form)
    no_repo? = form.params.repository_id == nil

    assigns =
      assign(assigns,
        p: form.params,
        options: options(form),
        selected: selected,
        no_repo?: no_repo?,
        no_options?: Enum.all?(form.repositories, &(not &1.available)),
        rebinding?:
          form.base.repository_id != nil and form.params.repository_id != form.base.repository_id,
        default_branch: selected && selected.default_branch,
        changed?: dirty?(form),
        mode: form.mode
      )
      |> assign_local(form)

    ~H"""
    <.side_panel
      id="project-github"
      show
      title={dgettext("ui", "仓库与合并 · %{key}", key: @project.key)}
      dirty={@changed?}
      patch_on_close={@close_path}
    >
      <:error :if={@form.alert}>
        <.icon name="lucide-circle-alert" class="mt-0.5 size-4 flex-none" />
        <span id="project-github-alert">{@form.alert}</span>
      </:error>
      <.form
        for={%{}}
        as={:project_github}
        id="project-github-form"
        phx-change="project_github_change"
        phx-submit="project_github_save"
        class="flex flex-col gap-6"
      >
        <fieldset disabled={@form.saving?} class="flex flex-col gap-4">
          <legend class="mb-2 text-label font-semibold text-fg">{dgettext("ui", "代码仓库")}</legend>
          <.mode_switch form={@form} />
          <div :if={@mode == :github} id="project-github-github-fields" class="flex flex-col gap-4">
            <input
              type="hidden"
              id="project-github-repository-id"
              name="project_github[repository_id]"
              value={@p.repository_id || ""}
            />
            <div class="flex flex-col gap-1">
              <span id="project-github-repository-label" class="text-label font-medium text-fg">
                {dgettext("ui", "仓库")}
              </span>
              <.dropdown
                id="project-github-repository"
                label={dgettext("ui", "选择仓库")}
                items={repository_items(@options, @p.repository_id)}
                popover_class="w-80"
                trigger_class="h-8 w-full justify-between border border-border-strong bg-surface px-3"
                class="w-full"
              >
                <:trigger>
                  <span class="flex min-w-0 items-center gap-1.5" id="project-github-repository-value">
                    <.icon :if={@selected && @selected.private} name="lucide-lock" class="size-3.5" />
                    <span class="truncate font-mono">
                      {(@selected && @selected.full_name) || dgettext("ui", "不绑定")}
                    </span>
                    <.badge :if={@selected && !@selected.available} tone={:warning}>
                      {dgettext("ui", "不可用")}
                    </.badge>
                  </span>
                  <.icon name="lucide-chevrons-up-down" class="size-4 text-fg-muted" />
                </:trigger>
              </.dropdown>
              <p
                :for={msg <- Map.get(@form.errors, :repository_id, [])}
                id="project-github-repository-error"
                class="flex items-center gap-1 text-caption text-danger-fg"
              >
                <.icon name="lucide-circle-alert" class="size-3.5" />{msg}
              </p>
              <p
                :if={@no_options?}
                id="project-github-no-repositories"
                class="text-caption text-fg-muted"
              >
                {dgettext("ui", "先在 GitHub 设置中连接 GitHub")}
                <.link
                  navigate={"/w/#{@slug}/settings/github"}
                  class="text-brand-fg hover:underline"
                >
                  {dgettext("ui", "前往 GitHub 设置")}
                </.link>
              </p>
            </div>
            <div
              :if={@rebinding?}
              id="project-github-rebind-warning"
              role="status"
              class="flex items-start gap-2 rounded-field border border-border tint-warning px-3 py-2 text-body text-warning-fg"
            >
              <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 flex-none" />
              {dgettext(
                "ui",
                "改绑后，原仓库里已开的 PR 不再由 Helmsman 管理（不再转草稿、关闭或合并），需要在 GitHub 上处理；进行中的任务的下一次运行会在新仓库建分支。"
              )}
            </div>
            <.input
              id="project-github-base-branch"
              name="project_github[base_branch]"
              label={dgettext("ui", "基础分支")}
              value={@p.base_branch}
              disabled={@no_repo?}
              list="project-github-branches"
              autocomplete="off"
              placeholder={@default_branch && dgettext("ui", "缺省：%{branch}", branch: @default_branch)}
              help={dgettext("ui", "留空使用仓库的默认分支；保存时会在 GitHub 上确认分支存在")}
              errors={Map.get(@form.errors, :base_branch, [])}
              phx-debounce="200"
              class="font-mono"
            />
            <datalist id="project-github-branches">
              <option :for={branch <- @form.branches} value={branch} />
            </datalist>
          </div>
          <.local_fields
            :if={@mode == :local}
            form={@form}
            options={@local_options}
            selected={@local_selected}
            rebinding?={@local_rebinding?}
            slug={@slug}
            project={@project}
          />
        </fieldset>

        <div
          :if={@mode == :local}
          id="project-github-local-merge"
          role="note"
          class="flex items-start gap-2 rounded-field border border-border tint-info px-3 py-2 text-body text-info-fg"
        >
          <.icon name="lucide-info" class="mt-0.5 size-4 flex-none" />
          <span>
            {dgettext(
              "ui",
              "本地模式没有 PR 与自动合并：Agent 的任务分支交付到所选仓库的 hm/<工作区 ID>/<任务> 分支，由人在本地审查与合并；Helmsman 不合并、不删分支。合并后会自动检测，检测不到（压缩、变基合并）时在任务上标记为已合并。"
            )}
          </span>
        </div>

        <fieldset
          :if={@mode == :github}
          disabled={@form.saving? or @no_repo?}
          class="flex flex-col gap-4"
        >
          <legend class="mb-2 text-label font-semibold text-fg">{dgettext("ui", "合并")}</legend>
          <p :if={@no_repo?} id="project-github-merge-disabled" class="text-caption text-fg-muted">
            {dgettext("ui", "绑定仓库后生效")}
          </p>
          <div
            role="radiogroup"
            aria-labelledby="project-github-merge-policy-label"
            class="flex flex-col gap-2"
          >
            <span id="project-github-merge-policy-label" class="text-label font-medium text-fg">
              {dgettext("ui", "合并策略")}
            </span>
            <label
              :for={{value, title, description, recommended?} <- policies()}
              for={"project-github-merge-policy-#{value}"}
              class={[
                "flex cursor-pointer items-start gap-2 rounded-field border px-3 py-2",
                if(@p.merge_policy == value,
                  do: "border-brand bg-selected",
                  else: "border-border hover:bg-hover"
                )
              ]}
            >
              <input
                type="radio"
                id={"project-github-merge-policy-#{value}"}
                name="project_github[merge_policy]"
                value={value}
                checked={@p.merge_policy == value}
                class="radio radio-sm mt-0.5 border-border-strong checked:text-brand"
              />
              <span class="flex min-w-0 flex-col">
                <span class="flex items-center gap-1.5 text-body text-fg">
                  {title}
                  <.badge :if={recommended?} tone={:brand}>{dgettext("ui", "推荐")}</.badge>
                </span>
                <span class="text-caption text-fg-muted">{description}</span>
              </span>
            </label>
          </div>
          <.input
            id="project-github-merge-method"
            name="project_github[merge_method]"
            type="select"
            label={dgettext("ui", "合并方式")}
            value={@p.merge_method}
            options={methods()}
          />
          <.input
            id="project-github-require-ci"
            name="project_github[require_ci]"
            type="checkbox"
            label={dgettext("ui", "要求 CI 通过")}
            checked={@p.require_ci}
            help={dgettext("ui", "没有任何检查时也不合并")}
          />
          <.input
            id="project-github-delete-branch"
            name="project_github[delete_branch_after_merge]"
            type="checkbox"
            label={dgettext("ui", "合并后删除任务分支")}
            checked={@p.delete_branch_after_merge}
          />
        </fieldset>
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="project-github-save"
            type="submit"
            form="project-github-form"
            variant="primary"
            disabled={!@changed? or @form.saving?}
          >
            {if(@form.saving?, do: dgettext("ui", "保存中…"), else: dgettext("ui", "保存"))}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  ## Local mode (add-local-repositories-ui D5)

  defp assign_local(assigns, form) do
    options = local_options(form)
    selected = Enum.find(options, &(&1.id == form.params.local_repository_id))
    base_id = form.base.local_repository_id

    assign(assigns,
      local_options: options,
      local_selected: selected,
      local_rebinding?: base_id != nil and form.params.local_repository_id != base_id
    )
  end

  @doc """
  The local repository options: the workspace's repositories, plus the bound one when it
  was removed (it may be kept, not chosen again).
  """
  def local_options(form) do
    current = form.current_local

    if current && not Enum.any?(form.locals, &(&1.id == current.id)),
      do: [current | form.locals],
      else: form.locals
  end

  attr :form, :map, required: true

  defp mode_switch(assigns) do
    assigns =
      assign(assigns,
        modes: [
          {:github, "project-github-mode-github", dgettext("ui", "GitHub 仓库"),
           "lucide-git-branch"},
          {:local, "project-github-mode-local", dgettext("ui", "本地仓库"), "lucide-hard-drive"}
        ],
        locked?: not can_switch?(assigns.form, other(assigns.form.mode))
      )

    ~H"""
    <div class="flex flex-col gap-1">
      <div
        id="project-github-mode"
        role="radiogroup"
        aria-label={dgettext("ui", "仓库类型")}
        class="inline-flex w-fit rounded-field border border-border bg-raised p-0.5"
      >
        <button
          :for={{mode, id, label, icon} <- @modes}
          id={id}
          type="button"
          role="radio"
          aria-checked={to_string(@form.mode == mode)}
          disabled={!can_switch?(@form, mode)}
          aria-describedby={!can_switch?(@form, mode) && "project-github-mode-locked"}
          phx-click="project_github_mode"
          phx-value-mode={mode}
          class={[
            "inline-flex h-7 items-center gap-1.5 rounded-field px-3 text-label",
            @form.mode == mode && "bg-surface text-fg shadow-sm",
            @form.mode != mode && "text-fg-muted hover:text-fg",
            "disabled:cursor-not-allowed disabled:text-fg-subtle disabled:hover:text-fg-subtle"
          ]}
        >
          <.icon name={icon} class="size-4" />{label}
        </button>
      </div>
      <p :if={@locked?} id="project-github-mode-locked" class="text-caption text-fg-muted">
        {dgettext("ui", "先在当前模式下选择『不绑定』并保存，再切换")}
      </p>
    </div>
    """
  end

  defp other(:github), do: :local
  defp other(:local), do: :github

  attr :form, :map, required: true
  attr :options, :list, required: true
  attr :selected, :map, default: nil
  attr :rebinding?, :boolean, required: true
  attr :slug, :string, required: true
  attr :project, :map, required: true

  defp local_fields(assigns) do
    p = assigns.form.params
    selected = assigns.selected

    assigns =
      assign(assigns,
        p: p,
        default_branch: selected && selected.default_branch,
        note: selected && LocalRepositoryComponents.status_note(selected)
      )

    ~H"""
    <div id="project-github-local-fields" class="flex flex-col gap-4">
      <input
        type="hidden"
        id="project-github-local-repository-id"
        name="project_github[local_repository_id]"
        value={@p.local_repository_id || ""}
      />
      <div class="flex flex-col gap-1">
        <span id="project-github-local-repository-label" class="text-label font-medium text-fg">
          {dgettext("ui", "本地仓库")}
        </span>
        <.dropdown
          id="project-github-local-repository"
          label={dgettext("ui", "选择本地仓库")}
          items={local_items(@options, @p.local_repository_id)}
          popover_class="w-80"
          trigger_class="h-8 w-full justify-between border border-border-strong bg-surface px-3"
          class="w-full"
        >
          <:trigger>
            <span class="flex min-w-0 items-center gap-1.5" id="project-github-local-repository-value">
              <.icon :if={@selected} name="lucide-hard-drive" class="size-3.5" />
              <span class="truncate font-mono">
                {(@selected && local_label(@selected)) || dgettext("ui", "不绑定")}
              </span>
              <.badge
                :if={@selected && LocalRepositoryComponents.status(@selected) != :online}
                tone={
                  @selected
                  |> LocalRepositoryComponents.status()
                  |> LocalRepositoryComponents.status_spec()
                  |> elem(0)
                }
              >
                {@selected
                |> LocalRepositoryComponents.status()
                |> LocalRepositoryComponents.status_spec()
                |> elem(1)}
              </.badge>
            </span>
            <.icon name="lucide-chevrons-up-down" class="size-4 text-fg-muted" />
          </:trigger>
        </.dropdown>
        <p
          :for={msg <- Map.get(@form.errors, :local_repository_id, [])}
          id="project-github-local-repository-error"
          class="flex items-center gap-1 text-caption text-danger-fg"
        >
          <.icon name="lucide-circle-alert" class="size-3.5" />{msg}
        </p>
        <p :if={@form.locals == []} id="project-github-no-locals" class="text-caption text-fg-muted">
          {dgettext("ui", "还没有机器向本工作区登记本地仓库")}
          <.link navigate={"/w/#{@slug}/settings/runtimes"} class="text-brand-fg hover:underline">
            {dgettext("ui", "前往运行时")}
          </.link>
        </p>
      </div>
      <div
        :if={@selected}
        id="project-github-local-info"
        class="flex flex-col gap-1 rounded-field border border-border bg-raised px-3 py-2 text-body text-fg-muted"
      >
        <code :if={@selected.path} class="break-all font-mono text-label text-fg" data-path>
          {@selected.path}
        </code>
        <p>
          {dgettext(
            "ui",
            "只有 %{machine}（%{owner}）上的运行时能执行这个项目的运行；指派给其他机器上 Agent 的运行会以『准备工作区』失败",
            machine: @selected.daemon_name,
            owner: @selected.owner.name
          )}
        </p>
        <p
          :if={@note}
          id="project-github-local-status"
          class="flex items-start gap-1 text-warning-fg"
        >
          <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 flex-none" />{@note}
        </p>
      </div>
      <div
        :if={@rebinding?}
        id="project-github-local-rebind-warning"
        role="status"
        class="flex items-start gap-2 rounded-field border border-border tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 flex-none" />
        {dgettext(
          "ui",
          "改绑或解绑后，已交付到原仓库的 hm/… 分支保留在原仓库；进行中任务在机器上的工作目录属于原仓库，下一次运行会以『准备工作区』失败，需要在机器上手工清理。建议先结束进行中的任务。"
        )}
      </div>
      <.input
        id="project-github-local-base-branch"
        name="project_github[base_branch]"
        label={dgettext("ui", "基础分支")}
        value={@p.base_branch}
        disabled={@p.local_repository_id == nil}
        list="project-github-local-branches"
        autocomplete="off"
        placeholder={
          if(@default_branch,
            do: dgettext("ui", "缺省：%{branch}", branch: @default_branch),
            else: dgettext("ui", "缺省：仓库当前检出的分支")
          )
        }
        help={dgettext("ui", "Helmsman 不在服务端检查分支是否存在；不存在时运行会以『准备工作区』失败")}
        errors={Map.get(@form.errors, :base_branch, [])}
        phx-debounce="200"
        class="font-mono"
      />
      <datalist id="project-github-local-branches">
        <option :if={@default_branch} value={@default_branch} />
      </datalist>
    </div>
    """
  end

  defp local_label(repository), do: "#{repository.name} · #{repository.daemon_name}"

  defp local_items(options, selected_id) do
    none = %{
      id: "project-github-local-repository-none",
      label: dgettext("ui", "不绑定"),
      checked: selected_id == nil,
      on_select: "project_github_local_repository",
      value: %{id: ""}
    }

    [
      none
      | Enum.map(options, fn repository ->
          {_tone, status} =
            repository
            |> LocalRepositoryComponents.status()
            |> LocalRepositoryComponents.status_spec()

          %{
            id: "project-github-local-repository-#{repository.id}",
            label: local_label(repository),
            icon: "lucide-hard-drive",
            description: "#{repository.owner.name} · #{status}",
            checked: repository.id == selected_id,
            on_select: "project_github_local_repository",
            value: %{id: repository.id}
          }
        end)
    ]
  end

  defp repository_items(options, selected_id) do
    none = %{
      id: "project-github-repository-none",
      label: dgettext("ui", "不绑定"),
      checked: selected_id == nil,
      on_select: "project_github_repository",
      value: %{id: ""}
    }

    [
      none
      | Enum.map(options, fn repository ->
          %{
            id: "project-github-repository-#{repository.id}",
            label: repository.full_name,
            icon: if(repository.private, do: "lucide-lock"),
            description: if(!repository.available, do: dgettext("ui", "不可用")),
            checked: repository.id == selected_id,
            on_select: "project_github_repository",
            value: %{id: repository.id}
          }
        end)
    ]
  end

  defp policies do
    [
      {"on_verified", dgettext("ui", "验收后自动合并"), dgettext("ui", "人或独立的 Agent 验收后，CI 通过即合并"),
       true},
      {"on_verified_human", dgettext("ui", "只在人验收后自动合并"),
       dgettext("ui", "Agent 验收的需要人在 GitHub 上合并或点立即合并"), false},
      {"manual", dgettext("ui", "不自动合并"), dgettext("ui", "只开 PR，由人合并"), false}
    ]
  end

  defp methods do
    [
      {dgettext("ui", "压缩合并"), "squash"},
      {dgettext("ui", "合并提交"), "merge"},
      {dgettext("ui", "变基合并"), "rebase"}
    ]
  end
end
