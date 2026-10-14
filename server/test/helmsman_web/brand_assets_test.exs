defmodule HelmsmanWeb.BrandAssetsTest do
  @moduledoc "web-visual-system「vendored 文件未被改动」(add-actor-avatars D1, tasks 1.1–1.2)."
  use ExUnit.Case, async: true

  alias HelmsmanWeb.Brands

  @dir Path.expand("../../priv/static/images/brand", __DIR__)
  @notices Path.expand("../../../THIRD_PARTY_NOTICES.md", __DIR__)

  defp manifest do
    @dir
    |> Path.join("MANIFEST.sha256")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [hash, name] = String.split(line, ~r/\s+/, parts: 2)
      {name, hash}
    end)
  end

  test "every vendored file matches its sha256 in MANIFEST.sha256" do
    for {name, hash} <- manifest() do
      digest = :crypto.hash(:sha256, File.read!(Path.join(@dir, name)))
      assert Base.encode16(digest, case: :lower) == hash, "#{name} was modified"
    end
  end

  test "the directory holds exactly the manifest, LICENSE and MANIFEST.sha256" do
    listed = manifest() |> Map.keys() |> Enum.sort()
    assert File.ls!(@dir) |> Enum.sort() == Enum.sort(["LICENSE", "MANIFEST.sha256" | listed])
  end

  test "every icon of the tables has its monochrome file, colour files only for them" do
    names = Brands.icon_names()
    assert length(names) == 49
    listed = manifest() |> Map.keys()

    for name <- names, do: assert("#{name}.svg" in listed, "missing #{name}.svg")

    for file <- listed do
      base = file |> String.replace_suffix(".svg", "") |> String.replace_suffix("-color", "")
      assert base in names, "#{file} is not in the tables"
    end
  end

  test "the upstream licence is MIT" do
    license = File.read!(Path.join(@dir, "LICENSE"))
    assert license =~ "MIT License"
    assert license =~ "Copyright (c) 2023 LobeHub"
  end

  test "THIRD_PARTY_NOTICES.md registers the version, source, licence and every file" do
    notices = File.read!(@notices)
    assert notices =~ "`@lobehub/icons-static-svg`"
    assert notices =~ "| 版本 | 1.95.1 |"
    assert notices =~ "https://github.com/lobehub/lobe-icons"
    assert notices =~ "server/priv/static/images/brand/MANIFEST.sha256"
    assert notices =~ "Copyright (c) 2023 LobeHub"
    assert notices =~ "商标"
    assert notices =~ "Lucide"
    assert notices =~ "ISC License"
    for name <- Map.keys(manifest()), do: assert(notices =~ "`#{name}`")
  end
end
