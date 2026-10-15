defmodule HelmsmanWeb.JsHooksTest do
  @moduledoc """
  Runs the Node tests of the JS hooks (`test/js/*_test.mjs`, `node --test`, no npm
  dependency): update-actor-icons D12, D15. Skipped when `node` is not installed.
  """
  use ExUnit.Case, async: true

  @node System.find_executable("node")
  @dir Path.expand("../js", __DIR__)

  if @node == nil, do: @tag(skip: "node is not installed")

  test "avatar cropper: a save still encoding never uploads after a tab switch" do
    {output, status} =
      System.cmd(
        @node,
        [
          "--disable-warning=MODULE_TYPELESS_PACKAGE_JSON",
          "--test",
          "--test-reporter=spec",
          "avatar_cropper_test.mjs"
        ],
        cd: @dir,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ ~r/ℹ fail 0/
  end
end
