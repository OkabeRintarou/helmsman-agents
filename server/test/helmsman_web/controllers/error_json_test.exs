defmodule HelmsmanWeb.ErrorJSONTest do
  # add-rest-api decision 5: the REST error body.
  use HelmsmanWeb.ConnCase, async: true

  alias HelmsmanWeb.ErrorJSON

  test "renders 404" do
    assert %{error: "not_found", message: message, detail: %{}} =
             ErrorJSON.render("404.json", %{})

    assert is_binary(message)
  end

  test "renders 500 without details" do
    assert %{error: "internal", detail: %{}} = ErrorJSON.render("500.json", %{})
  end

  test "status codes and parser errors have their codes" do
    for {template, code} <- [
          {"400.json", "bad_request"},
          {"406.json", "not_acceptable"},
          {"413.json", "payload_too_large"},
          {"415.json", "unsupported_media_type"},
          {"502.json", "internal"}
        ] do
      assert %{error: ^code} = ErrorJSON.render(template, %{})
    end

    parse_error = %Plug.Parsers.ParseError{exception: %Jason.DecodeError{position: 0, data: "{"}}
    assert %{error: "invalid_json"} = ErrorJSON.render("400.json", %{reason: parse_error})

    too_large = %Plug.Parsers.RequestTooLargeError{}
    assert %{error: "payload_too_large"} = ErrorJSON.render("413.json", %{reason: too_large})
  end
end
