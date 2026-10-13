defmodule HelmsmanWeb.UserLive.ProviderAccountHeadersLogTest do
  @moduledoc """
  add-provider-account-headers code-review-3 P1-1: the header values of the account
  panel never reach the LiveView event log (`HANDLE EVENT` at debug), with Phoenix's
  default parameter filter and with the domain's planned one, for `phx-change` and for
  failed and successful submits.
  """
  # Logger's level and the parameter filter are global.
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import Helmsman.AccountsFixtures
  import HelmsmanWeb.PortalHelpers

  @path "/users/settings/provider-accounts"

  setup %{conn: conn} do
    previous_filter = Application.fetch_env(:phoenix, :filter_parameters)
    previous_level = Logger.level()

    on_exit(fn ->
      case previous_filter do
        {:ok, value} -> Application.put_env(:phoenix, :filter_parameters, value)
        :error -> Application.delete_env(:phoenix, :filter_parameters)
      end

      Logger.configure(level: previous_level)
    end)

    Logger.configure(level: :debug)
    %{conn: log_in_user(conn, user_fixture())}
  end

  defp new_codex(conn) do
    {:ok, view, _html} = live(conn, @path <> "?panel=new")
    render_change(view, "account_form_change", %{"account" => %{"cli" => "codex"}})
    render_click(view, "account_form_header_add", %{})
    render_click(view, "account_form_header_add", %{})

    # The form really sends the values in the filtered subtree.
    names =
      view
      |> portal("provider-account-panel")
      |> LazyHTML.query("[data-new-header] input[type=password]")
      |> LazyHTML.attribute("name")

    assert names == ["account[headers_password][new][1]", "account[headers_password][new][2]"]
    view
  end

  # The parameters as the rendered form sends them.
  defp params(names, values, existing) do
    %{
      "name" => "apim-#{System.unique_integer([:positive])}",
      "cli" => "codex",
      "base_url" => "https://gw.example.com/openai/v1",
      "models" => %{"default" => "gpt-6-luna"},
      "new" => Map.new(names, fn {id, name} -> {id, %{"name" => name}} end),
      "headers_password" => %{"new" => values, "existing" => existing}
    }
  end

  defp sentinels,
    do: for(k <- ~w(new1 new2 old), do: "HDR_LOG_#{k}_#{System.unique_integer([:positive])}")

  for {label, filter} <- [
        {"the configured filter", :default},
        {"the domain's planned filter", ["password", "secret", "api_key", "headers"]}
      ] do
    test "change and submits never log a header value (#{label})", %{conn: conn} do
      case unquote(Macro.escape(filter)) do
        # As configured for the test run (Phoenix's own default: ["password"]).
        :default -> :ok
        list -> Application.put_env(:phoenix, :filter_parameters, list)
      end

      view = new_codex(conn)
      [a, b, old] = values = sentinels()
      existing = %{"0" => old}

      log =
        capture_log([level: :debug], fn ->
          render_change(view, "account_form_change", %{
            "account" => params([{"1", "user"}], %{"1" => a}, existing)
          })

          # Fails locally (duplicate names), then succeeds.
          render_submit(view, "account_form_submit", %{
            "account" =>
              params([{"1", "user"}, {"2", "USER"}], %{"1" => a, "2" => b}, existing)
              |> Map.put("api_key", "k-1")
          })

          render_submit(view, "account_form_submit", %{
            "account" =>
              params([{"1", "user"}, {"2", "x-b"}], %{"1" => a, "2" => b}, existing)
              |> Map.put("api_key", "k-1")
          })
        end)

      # The LiveView event entries only: the domain's own logging (Ecto queries) is
      # checked by the domain's tests.
      events =
        log
        |> String.split(~r/^(?=\d\d:\d\d:\d\d\.\d+ \[)/m)
        |> Enum.filter(&(&1 =~ "HANDLE EVENT"))
        |> Enum.join()

      assert events =~ ~s(HANDLE EVENT "account_form_change")
      assert events =~ ~s(HANDLE EVENT "account_form_submit")
      assert events =~ "[FILTERED]"
      for value <- values, do: refute(events =~ value)
    end
  end
end
