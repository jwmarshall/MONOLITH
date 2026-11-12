defmodule Monolith.StageDesigner.JPEGTest do
  use ExUnit.Case, async: false

  alias Monolith.StageDesigner.Image
  alias Monolith.StageDesigner.JPEG, as: JPEGValidator
  alias Monolith.TestSupport.JPEG
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @decoder {Operation, :jpegload_buffer, 2}

  setup context do
    if context[:decoder_trace] do
      Code.ensure_loaded!(Operation)
      # call_count traces actual loader entry without copying the encoded image
      # into trace messages. The pattern is global: this module must stay synchronous.
      assert :erlang.trace_pattern(@decoder, true, [:call_count]) == 1
      on_exit(fn -> :erlang.trace_pattern(@decoder, false, [:call_count]) end)
    end

    :ok
  end

  test "fully decodes baseline, progressive, grayscale and widescreen JPEG fixtures" do
    for {width, height, opts} <- [
          {2, 2, []},
          {3, 7, [progressive: true]},
          {8, 8, [bands: 1]},
          {1376, 768, []}
        ] do
      bytes = JPEG.image(width, height, opts)
      assert Image.format(bytes) == :jpeg
      assert Image.extension(:jpeg) == "jpg"
      assert Image.mime_type(:jpeg) == "image/jpeg"
      assert :ok = Image.validate(bytes)
    end
  end

  test "accepts original metadata without rewriting or transcoding bytes" do
    bytes = JPEG.image() |> JPEG.with_metadata()
    assert :ok = Image.validate(bytes)
    assert bytes =~ "Synthetic provenance"
  end

  test "rejects incomplete entropy data even when headers and final EOI are present" do
    bytes = JPEG.image(64, 64)
    {sos, 2} = :binary.match(bytes, <<0xFF, 0xDA>>)
    <<length::16>> = binary_part(bytes, sos + 2, 2)
    header = binary_part(bytes, 0, sos + 2 + length)
    assert {:error, :invalid_image} = Image.validate(header <> <<0xFF, 0xD9>>)
  end

  test "rejects truncation, wrong formats, and trailing container bytes" do
    valid = JPEG.image()

    for bytes <- [
          <<0xFF, 0xD8>>,
          <<0xFF, 0xD8, 0xFF, 0xD9>>,
          binary_part(valid, 0, byte_size(valid) - 1),
          valid <> "trailing",
          <<0xFF, 0xD8, 0xFF, 0xE1, 100::16, 0xFF, 0xD9>>
        ] do
      assert {:error, :invalid_image} = Image.validate(bytes)
    end
  end

  for {limit, control, oversized} <- [
        {"width", {8192, 1}, {8193, 1}},
        {"height", {1, 8192}, {1, 8193}},
        {"pixel count", {4000, 4000}, {4001, 4000}}
      ] do
    @tag :decoder_trace
    test "preflights otherwise-valid JPEGs above the #{limit} limit before native loading" do
      {width, height} = unquote(control)
      control = monochrome_jpeg(width, height)
      before = decoder_calls()
      assert :ok = Image.validate(control)
      assert decoder_calls() == before + 1

      {width, height} = unquote(oversized)
      bytes = monochrome_jpeg(width, height)
      assert byte_size(bytes) < 256 * 1024
      # Independently force strict native decoding: these are real entropy-coded
      # images, not SOF-only frames. The largest evaluation is ~16 MiB grayscale.
      assert_native_pixels(bytes, width, height)
      assert_preflight_rejected(bytes)
    end
  end

  @tag :decoder_trace
  test "encoded JPEG byte limit discriminates valid COM metadata before native loading" do
    max_bytes = 10 * 1024 * 1024
    base = monochrome_jpeg(1, 1)
    control = pad_with_comments(base, max_bytes)
    assert byte_size(control) == max_bytes
    before = decoder_calls()
    assert :ok = Image.validate(control)
    assert decoder_calls() == before + 1

    bytes = pad_with_comments(base, max_bytes + 1)
    assert byte_size(bytes) == max_bytes + 1
    assert_native_pixels(bytes, 1, 1)
    assert_preflight_rejected(bytes)
  end

  test "rejects zero dimensions and unsupported precision" do
    for {width, height} <- [{0, 1}, {1, 0}] do
      assert {:error, :invalid_image} = Image.validate(frame(width, height))
    end

    assert {:error, :invalid_image} = Image.validate(frame(1, 1, 12))
  end

  test "rejects excessive header fill markers without allocating native pixels" do
    bytes = <<0xFF, 0xD8>> <> :binary.copy(<<0xFF>>, 1025) <> <<0xD9>>
    assert {:error, :invalid_image} = Image.validate(bytes)
  end

  defp decoder_calls do
    {:call_count, count} = :erlang.trace_info(@decoder, :call_count)
    assert is_integer(count)
    count
  end

  defp assert_preflight_rejected(bytes) do
    before = decoder_calls()
    assert {:error, :invalid_image} = Image.validate(bytes)
    # Also protect JPEG's own byte guard, independently of Image's dispatch.
    assert {:error, :invalid_image} = JPEGValidator.validate(bytes)
    assert decoder_calls() == before
  end

  defp assert_native_pixels(bytes, width, height) do
    before = decoder_calls()

    assert {:ok, {image, _flags}} =
             Operation.jpegload_buffer(bytes,
               "fail-on": :VIPS_FAIL_ON_WARNING,
               access: :VIPS_ACCESS_SEQUENTIAL,
               revalidate: true
             )

    assert decoder_calls() == before + 1
    assert VipsImage.width(image) == width
    assert VipsImage.height(image) == height
    assert VipsImage.bands(image) == 1
    assert VipsImage.format(image) == :VIPS_FORMAT_UCHAR
    assert {:ok, pixels} = VipsImage.write_to_binary(image)
    assert byte_size(pixels) == width * height
  end

  defp monochrome_jpeg(width, height) do
    # A lazy constant image avoids allocating an RGB source just to encode it.
    {:ok, image} = Operation.black(width, height, bands: 1)
    {:ok, bytes} = Operation.jpegsave_buffer(image, Q: 90)
    bytes
  end

  defp pad_with_comments(<<0xFF, 0xD8, rest::binary>> = bytes, target) do
    # COM payloads are opaque; each segment obeys JPEG's 16-bit length limit.
    # ~161 segments at 10 MiB stay far below the 1024-segment preflight cap.
    padding = comment_segments(target - byte_size(bytes))
    IO.iodata_to_binary([<<0xFF, 0xD8>>, padding, rest])
  end

  defp comment_segments(0), do: []

  defp comment_segments(remaining) when remaining >= 4 do
    size = min(remaining, 65_537)
    payload = :binary.copy("x", size - 4)
    [<<0xFF, 0xFE, size - 2::16, payload::binary>> | comment_segments(remaining - size)]
  end

  defp frame(width, height, precision \\ 8) do
    <<0xFF, 0xD8, 0xFF, 0xC0, 11::16, precision, height::16, width::16, 1, 1, 0x11, 0, 0xFF,
      0xD9>>
  end
end
