defmodule Helmsman.AvatarsFixtures do
  @moduledoc """
  Image bytes for avatar tests (`add-actor-avatars`), built here instead of
  stored: `png/2` is a complete, decodable PNG; the JPEG and WebP files
  only have valid headers, which is all `Helmsman.Avatars.Image` reads.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Bitwise

  @doc """
  A PNG of `w`×`h` (`opts`: `:color` an RGBA tuple, `:apng` adds an
  `acTL` chunk before the image data).
  """
  def png(w, h, opts \\ []) do
    {r, g, b, a} = Keyword.get(opts, :color, {32, 96, 160, 255})
    row = <<0>> <> :binary.copy(<<r, g, b, a>>, w)
    idat = :zlib.compress(:binary.copy(row, h))
    actl = if opts[:apng], do: chunk("acTL", <<1::32, 0::32>>), else: ""

    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <>
      chunk("IHDR", <<w::32, h::32, 8, 6, 0, 0, 0>>) <>
      actl <> chunk("IDAT", idat) <> chunk("IEND", "")
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>

  @doc """
  A JPEG header of `w`×`h` (SOF0 after an APP0 and a DHT segment), padded
  with comment segments to `size` bytes when given.
  """
  def jpeg(w, h, size \\ nil) do
    app0 = segment(0xE0, "JFIF" <> <<0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>)
    dht = segment(0xC4, <<0>> <> :binary.copy(<<0>>, 16))
    sof = segment(0xC0, <<8, h::16, w::16, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1>>)
    body = <<0xFF, 0xD8>> <> app0 <> dht <> sof
    pad(body, size) <> <<0xFF, 0xD9>>
  end

  defp segment(marker, data), do: <<0xFF, marker, byte_size(data) + 2::16>> <> data

  defp pad(body, nil), do: body

  defp pad(body, size) do
    case size - byte_size(body) - 2 do
      n when n <= 0 -> body
      n when n < 4 -> body <> :binary.copy(<<0xFF>>, n)
      n -> pad(body <> segment(0xFE, :binary.copy("x", min(n - 4, 65_000))), size)
    end
  end

  @doc """
  A WebP header of `w`×`h`: `:vp8x` (default; `animated: true` sets the
  animation flag), `:vp8l` or `:vp8`.
  """
  def webp(w, h, format \\ :vp8x, opts \\ []) do
    chunk =
      case format do
        :vp8x ->
          flags = if opts[:animated], do: 0x02, else: 0x10
          riff_chunk("VP8X", <<flags, 0, 0, 0, w - 1::little-24, h - 1::little-24>>)

        :vp8l ->
          bits = w - 1 ||| (h - 1) <<< 14 ||| 1 <<< 28
          riff_chunk("VP8L", <<0x2F, bits::little-32, 0>>)

        :vp8 ->
          riff_chunk("VP8 ", <<0x10, 0x02, 0x00, 0x9D, 0x01, 0x2A, w::little-16, h::little-16>>)
      end

    "RIFF" <> <<byte_size(chunk) + 4::little-32>> <> "WEBP" <> chunk
  end

  defp riff_chunk(type, data) do
    padding = if rem(byte_size(data), 2) == 1, do: <<0>>, else: ""
    type <> <<byte_size(data)::little-32>> <> data <> padding
  end

  @doc "A GIF header (not an accepted type)."
  def gif(w, h), do: "GIF89a" <> <<w::little-16, h::little-16, 0, 0, 0>> <> ";"
end
