defmodule HelmsmanProtocol.DeviceAuthTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{DeviceAuth, ErrorReply, Fixtures}

  test "HTTP constants, device code request and response" do
    assert DeviceAuth.code_path() == "/daemon/device/code"
    assert DeviceAuth.token_path() == "/daemon/device/token"
    assert DeviceAuth.logout_path() == "/daemon/logout"
    request = %{"protocol" => 1, "machine" => Fixtures.machine()}
    assert {:ok, value} = DeviceAuth.CodeRequest.from_wire(request)
    assert DeviceAuth.CodeRequest.to_wire(value) == request

    assert {:error, {:invalid_payload, ["protocol"], :required}} =
             DeviceAuth.CodeRequest.from_wire(Map.delete(request, "protocol"))

    response = %{
      "device_code" => "private-code",
      "user_code" => "ABCD-EF2H",
      "verification_uri" => "https://h.example/device",
      "verification_uri_complete" => "https://h.example/device?code=ABCD-EF2H",
      "expires_in" => 900,
      "interval" => 5
    }

    assert {:ok, value} = DeviceAuth.CodeResponse.from_wire(response)
    assert DeviceAuth.CodeResponse.to_wire(value) == response

    assert {:error, {:invalid_payload, ["user_code"], :type}} =
             DeviceAuth.CodeResponse.from_wire(Map.put(response, "user_code", "ABCD-EF0H"))

    assert {:ok, value} = DeviceAuth.TokenRequest.from_wire(%{"device_code" => "private-code"})
    assert DeviceAuth.TokenRequest.to_wire(value) == %{"device_code" => "private-code"}
  end

  test "polling maps all four HTTP 400 flow errors" do
    assert DeviceAuth.decode_token_reply(400, %{"error" => "authorization_pending"}) ==
             {:pending, :authorization_pending}

    assert DeviceAuth.decode_token_reply(400, %{"error" => "slow_down"}) == {:pending, :slow_down}

    assert DeviceAuth.decode_token_reply(400, %{"error" => "expired_token"}) ==
             {:error, :expired_token}

    assert DeviceAuth.decode_token_reply(400, %{"error" => "access_denied"}) ==
             {:error, :access_denied}

    assert {:error, {:invalid_payload, ["error"], _}} =
             DeviceAuth.decode_token_reply(400, %{"error" => "surprise"})

    assert {:error, {:invalid_payload, ["error"], :required}} =
             DeviceAuth.decode_token_reply(400, %{})
  end

  test "success returns daemon topic identity and hides the hmd token" do
    payload = %{
      "token" => "hmd_private-token",
      "daemon_id" => 42,
      "workspaces" => [%{"id" => 1, "slug" => "team", "name" => "Team"}]
    }

    assert {:ok, value} = DeviceAuth.decode_token_reply(200, payload)
    assert HelmsmanProtocol.topic(value.daemon_id) == "daemon:42"
    refute inspect(value) =~ "hmd_private-token"
    assert DeviceAuth.TokenResponse.to_wire(value) == payload

    assert {:error, {:invalid_payload, ["token"], :type}} =
             DeviceAuth.decode_token_reply(200, Map.put(payload, "token", "hmr_wrong"))

    assert {:error, {:invalid_payload, ["daemon_id"], :required}} =
             DeviceAuth.decode_token_reply(200, Map.delete(payload, "daemon_id"))
  end

  test "HTTP 426 validates structured version details before returning incompatibility" do
    assert {:ok, error} = ErrorReply.unsupported_protocol("https://h.example/install.sh")

    assert DeviceAuth.decode_token_reply(426, ErrorReply.to_wire(error)) ==
             {:error, :unsupported_protocol}

    assert {:error, {:invalid_payload, ["server_version"], :required}} =
             DeviceAuth.decode_token_reply(426, %{
               "reason" => "unsupported_protocol",
               "message" => "x"
             })

    assert {:error, {:invalid_payload, [], :type}} = DeviceAuth.decode_token_reply(500, %{})
  end

  test "user code alphabet and exact format exclude confusing characters" do
    assert DeviceAuth.user_code_alphabet() == "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    for char <- ~w(0 O 1 I L), do: refute(DeviceAuth.user_code_alphabet() =~ char)
    assert DeviceAuth.valid_user_code?("ABCD-EF2H")

    for code <- ["ABCD-EF0H", "abcd-EF2H", "ABCDEFGH", "ABCD-EF2HH", "ABCD-EFOH", nil, 1],
        do: refute(DeviceAuth.valid_user_code?(code))
  end
end
