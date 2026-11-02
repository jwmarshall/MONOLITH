defmodule Lovelace.StageDesigner.JPEG do
  @moduledoc "Bounded JPEG preflight and strict full pixel decoding; original bytes remain untouched."

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @max_bytes 10 * 1024 * 1024
  @frames [0xC0, 0xC1, 0xC2]

  def validate(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, {width, height}} <- dimensions(bytes),
         {:ok, {image, _flags}} <-
           Operation.jpegload_buffer(bytes,
             "fail-on": :VIPS_FAIL_ON_WARNING,
             access: :VIPS_ACCESS_SEQUENTIAL,
             revalidate: true
           ),
         true <- VipsImage.width(image) == width and VipsImage.height(image) == height,
         bands when bands in 1..4 <- VipsImage.bands(image),
         :VIPS_FORMAT_UCHAR <- VipsImage.format(image),
         {:ok, pixels} <- VipsImage.write_to_binary(image),
         true <- byte_size(pixels) == width * height * bands do
      :ok
    else
      _ -> {:error, :invalid_image}
    end
  rescue
    _ -> {:error, :invalid_image}
  catch
    _, _ -> {:error, :invalid_image}
  end

  def validate(_), do: {:error, :invalid_image}

  # Inspect bounded segment headers before ANY native load/allocation. The decoder
  # remains JPEG-specific, compares its dimensions, and must fully evaluate pixels.
  defp dimensions(<<0xFF, 0xD8, rest::binary>> = bytes) do
    if byte_size(bytes) >= 4 and binary_part(bytes, byte_size(bytes) - 2, 2) == <<0xFF, 0xD9>>,
      do: frame(rest, 0),
      else: {:error, :invalid_image}
  end

  defp dimensions(_), do: {:error, :invalid_image}

  defp frame(<<0xFF, 0xFF, rest::binary>>, count) when count < 1024,
    do: frame(<<0xFF, rest::binary>>, count + 1)

  defp frame(<<0xFF, marker, length::16, rest::binary>>, count)
       when count < 1024 and length >= 2 and marker not in [0, 0xD8, 0xD9, 0xDA] do
    size = length - 2

    case rest do
      <<segment::binary-size(^size), tail::binary>> -> segment(marker, segment, tail, count)
      _ -> {:error, :invalid_image}
    end
  end

  defp frame(_bytes, _count), do: {:error, :invalid_image}

  defp segment(marker, <<8, height::16, width::16, components, rest::binary>>, _tail, _count)
       when marker in @frames and components in [1, 3, 4] do
    if width in 1..8192 and height in 1..8192 and width * height <= 16_000_000 and
         byte_size(rest) == components * 3,
       do: {:ok, {width, height}},
       else: {:error, :invalid_image}
  end

  # Skip bounded metadata/table segments, never entropy data or unsupported frames.
  defp segment(marker, _segment, tail, count)
       when marker in 0xE0..0xEF or marker in [0xFE, 0xDB, 0xC4, 0xDD] do
    frame(tail, count + 1)
  end

  defp segment(_marker, _segment, _tail, _count), do: {:error, :invalid_image}
end
