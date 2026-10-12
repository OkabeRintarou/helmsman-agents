defmodule HelmsmanProtocol.DeviceAuth do
  @moduledoc "JSON device authorization and logout HTTP conventions."
  alias HelmsmanProtocol.{DeviceAuth.TokenResponse, ErrorReply, Schema}

  @alphabet "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @errors %{
    "authorization_pending" => {:pending, :authorization_pending},
    "slow_down" => {:pending, :slow_down},
    "expired_token" => {:error, :expired_token},
    "access_denied" => {:error, :access_denied}
  }
  @spec code_path() :: String.t()
  def code_path, do: "/daemon/device/code"
  @spec token_path() :: String.t()
  def token_path, do: "/daemon/device/token"
  @spec logout_path() :: String.t()
  def logout_path, do: "/daemon/logout"
  @spec user_code_alphabet() :: String.t()
  def user_code_alphabet, do: @alphabet
  @spec valid_user_code?(term()) :: boolean()
  def valid_user_code?(<<left::binary-size(4), "-", right::binary-size(4)>>) do
    Enum.all?(:binary.bin_to_list(left <> right), &(&1 in :binary.bin_to_list(@alphabet)))
  end

  def valid_user_code?(_), do: false

  @spec decode_token_reply(integer(), map()) ::
          {:ok, TokenResponse.t()}
          | {:pending, :authorization_pending | :slow_down}
          | {:error, :expired_token | :access_denied | :unsupported_protocol | Schema.error()}
  def decode_token_reply(200, payload), do: TokenResponse.from_wire(payload)

  def decode_token_reply(400, %{"error" => code}) do
    Map.get(@errors, code, Schema.invalid(["error"], {:enum, Map.keys(@errors)}))
  end

  def decode_token_reply(426, payload) do
    case ErrorReply.from_wire(payload) do
      {:ok, %{reason: :unsupported_protocol}} -> {:error, :unsupported_protocol}
      {:ok, _} -> Schema.invalid(["reason"], :not_allowed)
      error -> error
    end
  end

  def decode_token_reply(400, payload) when is_map(payload),
    do: Schema.invalid(["error"], :required)

  def decode_token_reply(_, _), do: Schema.invalid([], :type)
end
