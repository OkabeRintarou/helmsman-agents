defmodule HelmsmanWeb.GitHubComponents do
  @moduledoc """
  GitHub visuals shared by the pages (add-github-ui D2): the repository chip of project
  headers and cards. The PR card components join it with the PR change group.
  """
  use HelmsmanWeb, :html

  @web_url "https://github.com"

  @doc "The GitHub page of the repository `full_name` (`owner/name`)."
  def repository_url(full_name), do: "#{@web_url}/#{full_name}"

  @doc """
  The bound repository of a project: `git-branch` icon, `owner/name` (a link to GitHub
  unless `link={false}`, e.g. inside a card that is itself a link), an optional
  `→ <branch>`, and a warning mark when the repository is unavailable.
  """
  attr :id, :string, required: true
  attr :repository, :map, required: true, doc: "`%{full_name, available}`"
  attr :branch, :string, default: nil
  attr :link, :boolean, default: true
  attr :class, :any, default: nil

  def repo_chip(assigns) do
    ~H"""
    <span
      id={@id}
      data-available={to_string(@repository.available)}
      class={["inline-flex min-w-0 items-center gap-1 text-caption text-fg-muted", @class]}
    >
      <.icon name="lucide-git-branch" class="size-3.5 flex-none" />
      <a
        :if={@link}
        href={repository_url(@repository.full_name)}
        target="_blank"
        rel="noopener noreferrer"
        class="truncate font-mono hover:text-fg hover:underline"
        data-repository
      >
        {@repository.full_name}
      </a>
      <span :if={!@link} class="truncate font-mono" data-repository>{@repository.full_name}</span>
      <span :if={@branch} class="flex-none" data-branch>
        → <span class="font-mono">{@branch}</span>
      </span>
      <.tooltip
        :if={!@repository.available}
        id={"#{@id}-unavailable"}
        text={dgettext("ui", "仓库不可用，不会开 PR 或合并")}
        class="flex-none"
      >
        <.icon
          name="lucide-triangle-alert"
          class="size-3.5 text-warning"
          label={dgettext("ui", "仓库不可用")}
          data-unavailable
        />
      </.tooltip>
    </span>
    """
  end
end
