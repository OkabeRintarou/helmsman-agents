defmodule HelmsmanWeb.Markdown.SnapshotTest do
  use HelmsmanWeb.MarkdownCase, async: true

  import Helmsman.ProjectsFixtures

  # Regenerate after an intended change with
  # UPDATE_MARKDOWN_SNAPSHOT=1 mix test test/helmsman_web/markdown/snapshot_test.exs
  @sample "test/support/fixtures/markdown/sample.md"
  @snapshot "test/support/fixtures/markdown/sample.html"

  @moduletag slug: "snapshot"

  setup %{scope: scope} do
    project_fixture(scope, key: "BOS", name: "Bosun")
    for _ <- 1..2, do: task_fixture(scope, "BOS")
    :ok
  end

  test "the sample renders as the snapshot, every time", %{scope: scope} do
    sample = File.read!(@sample)
    html = render(sample, scope, anchor_ns: "desc", mentions: ["keel/dev"])

    if System.get_env("UPDATE_MARKDOWN_SNAPSHOT") == "1", do: File.write!(@snapshot, html)

    assert html == File.read!(@snapshot)
    assert render(sample, scope, anchor_ns: "desc", mentions: ["keel/dev"]) == html
  end
end
