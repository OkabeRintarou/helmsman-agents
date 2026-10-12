defmodule HelmsmanWeb.MarkdownCase do
  @moduledoc """
  Test case for `HelmsmanWeb.Markdown`: a workspace scope in `ctx.scope`
  (its slug from the `:slug` module tag, if any) and helpers to render and
  query the output.
  """

  # Test-only helpers used by web test cases.
  use Boundary, top_level?: true, check: [in: false, out: false]

  use ExUnit.CaseTemplate

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  using do
    quote do
      import HelmsmanWeb.MarkdownCase
    end
  end

  setup tags do
    Helmsman.DataCase.setup_sandbox(tags)
    owner = user_fixture()
    attrs = if tags[:slug], do: %{slug: tags[:slug]}, else: %{}
    %{scope: workspace_scope_fixture(owner, workspace_fixture(owner, attrs))}
  end

  @doc "Renders `markdown` as `scope` (namespace `desc` unless given) to a string."
  def render(markdown, scope, opts \\ []) do
    opts = Keyword.merge([scope: scope, anchor_ns: "desc"], opts)
    {:safe, html} = HelmsmanWeb.Markdown.to_html(markdown, opts)
    html
  end

  @doc "Parses rendered HTML."
  def parse(html), do: LazyHTML.from_fragment(html)

  @doc "The values of `attribute` on the elements matching `selector`."
  def attrs(html, selector, attribute),
    do: html |> parse() |> LazyHTML.query(selector) |> LazyHTML.attribute(attribute)

  @doc "Counts the elements matching `selector`."
  def count(html, selector), do: html |> parse() |> LazyHTML.query(selector) |> Enum.count()

  @doc "Runs `fun` and counts the repo queries it made from this process."
  def count_queries(fun) do
    test_pid = self()
    handler = "markdown-queries-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:helmsman, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == test_pid, do: send(test_pid, :markdown_query)
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(n) do
    receive do
      :markdown_query -> drain(n + 1)
    after
      0 -> n
    end
  end
end
