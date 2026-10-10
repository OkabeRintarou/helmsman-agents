defmodule Helmsman.RepoExtensionsTest do
  use Helmsman.DataCase, async: true

  test "citext and pg_trgm extensions are enabled" do
    %{rows: rows} =
      Repo.query!("SELECT extname FROM pg_extension WHERE extname IN ('citext', 'pg_trgm')")

    assert rows |> List.flatten() |> Enum.sort() == ["citext", "pg_trgm"]
  end
end
