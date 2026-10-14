defmodule Helmsman.Avatars.Image do
  @moduledoc """
  Checks an avatar file (`add-actor-avatars` decision 4) from its bytes
  alone: the type by its signature (PNG, JPEG or WebP; the declared type
  and the file name are never trusted), the size, a square edge of 32 to
  1024 pixels read from the header, and no animation (an APNG `acTL`
  chunk before the image data, or the animation flag of a WebP `VP8X`
  chunk). Pixels are never decoded.
  """

  import Bitwise

  @max_bytes 262_144
  @min_edge 32
  @max_edge 1024

  @type content_type :: String.t()
  @type error ::
          :unsupported_type
          | :invalid_image
          | :too_large
          | :not_square
          | :bad_dimensions
          | :animated

  @doc "The largest file accepted, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The content types an avatar can have."
  @spec content_types() :: [content_type()]
  def content_types, do: ~w(image/png image/jpeg image/webp)

  @doc """
  Checks `data`. Returns the content type and the edge in pixels, or the
  first problem found: empty → `:invalid_image`, more than
  #{@max_bytes} bytes → `:too_large`, an unknown signature →
  `:unsupported_type`, an unreadable header → `:invalid_image`, then
  `:animated`, `:not_square` and `:bad_dimensions`.
  """
  @spec validate(term()) ::
          {:ok, %{content_type: content_type(), edge: pos_integer()}} | {:error, error()}
  def validate(data) when is_binary(data) do
    with :ok <- check_size(data),
         {:ok, type} <- detect(data),
         {:ok, %{width: w, height: h, animated: animated}} <- header(type, data),
         :ok <- if(animated, do: {:error, :animated}, else: :ok),
         :ok <- if(w == h, do: :ok, else: {:error, :not_square}),
         :ok <- if(w in @min_edge..@max_edge//1, do: :ok, else: {:error, :bad_dimensions}) do
      {:ok, %{content_type: type, edge: w}}
    end
  end

  def validate(_data), do: {:error, :invalid_image}

  defp check_size(""), do: {:error, :invalid_image}
  defp check_size(data) when byte_size(data) > @max_bytes, do: {:error, :too_large}
  defp check_size(_data), do: :ok

  defp detect(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: {:ok, "image/png"}
  defp detect(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp detect(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  defp detect(_data), do: {:error, :unsupported_type}

  defp header(type, data) do
    case parse(type, data) do
      {:ok, %{width: w, height: h}} = ok when is_integer(w) and is_integer(h) -> ok
      _ -> {:error, :invalid_image}
    end
  end

  ## PNG: IHDR first, then the chunks up to the first IDAT.

  defp parse(
         "image/png",
         <<_sig::binary-size(8), 13::32, "IHDR", w::32, h::32, _rest::binary-size(5),
           _crc::binary-size(4), chunks::binary>>
       ) do
    with {:ok, animated} <- png_chunks(chunks),
         do: {:ok, %{width: w, height: h, animated: animated}}
  end

  ## JPEG: the segments up to the first frame header.

  defp parse("image/jpeg", <<0xFF, 0xD8, rest::binary>>), do: jpeg_segments(rest)

  ## WebP: the first chunk after the RIFF header.

  defp parse(
         "image/webp",
         <<"RIFF", _::binary-size(4), "WEBP", "VP8 ", _size::little-32, _tag::binary-size(3),
           0x9D, 0x01, 0x2A, w::little-16, h::little-16, _::binary>>
       ),
       do: {:ok, %{width: w &&& 0x3FFF, height: h &&& 0x3FFF, animated: false}}

  defp parse(
         "image/webp",
         <<"RIFF", _::binary-size(4), "WEBP", "VP8L", _size::little-32, 0x2F, bits::little-32,
           _::binary>>
       ),
       do:
         {:ok,
          %{width: (bits &&& 0x3FFF) + 1, height: (bits >>> 14 &&& 0x3FFF) + 1, animated: false}}

  defp parse(
         "image/webp",
         <<"RIFF", _::binary-size(4), "WEBP", "VP8X", _size::little-32, flags,
           _reserved::binary-size(3), w::little-24, h::little-24, _::binary>>
       ),
       do: {:ok, %{width: w + 1, height: h + 1, animated: (flags &&& 0x02) != 0}}

  defp parse(_type, _data), do: :error

  defp png_chunks(<<_len::32, "acTL", _::binary>>), do: {:ok, true}
  defp png_chunks(<<_len::32, "IDAT", _::binary>>), do: {:ok, false}

  defp png_chunks(<<len::32, _type::binary-size(4), rest::binary>>) do
    case rest do
      <<_data::binary-size(^len), _crc::binary-size(4), more::binary>> -> png_chunks(more)
      _ -> :error
    end
  end

  defp png_chunks(_data), do: :error

  # Fill bytes before a marker.
  defp jpeg_segments(<<0xFF, 0xFF, rest::binary>>), do: jpeg_segments(<<0xFF, rest::binary>>)

  # Markers without a length: TEM and RST0-7.
  defp jpeg_segments(<<0xFF, marker, rest::binary>>) when marker == 0x01 or marker in 0xD0..0xD7,
    do: jpeg_segments(rest)

  # SOF0-SOF15, except DHT (C4), JPG (C8) and DAC (CC).
  defp jpeg_segments(<<0xFF, marker, _len::16, _precision, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: {:ok, %{width: w, height: h, animated: false}}

  # End of image or start of scan before any frame header.
  defp jpeg_segments(<<0xFF, marker, _::binary>>) when marker in [0xD9, 0xDA], do: :error

  defp jpeg_segments(<<0xFF, _marker, len::16, rest::binary>>) when len >= 2 do
    skip = len - 2

    case rest do
      <<_data::binary-size(^skip), more::binary>> -> jpeg_segments(more)
      _ -> :error
    end
  end

  defp jpeg_segments(_data), do: :error
end
