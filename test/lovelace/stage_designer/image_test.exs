defmodule Lovelace.StageDesigner.ImageTest do
  use ExUnit.Case, async: false

  alias Lovelace.StageDesigner.Image
  alias Lovelace.TestSupport.PNG

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  test "accepts small static PNGs without a minimum dimension" do
    for {width, height} <- [{1, 1}, {2, 2}, {3, 7}, {8192, 1}, {1, 8192}] do
      assert :ok = Image.validate(PNG.image(width, height))
    end
  end

  test "validates all filter values and split IDAT streams" do
    raw = for filter <- 0..4, into: <<>>, do: <<filter, 1, 2, 3, 4>>
    compressed = :zlib.compress(raw)
    <<first::binary-size(3), second::binary>> = compressed
    png = assemble(header(1, 5), [PNG.chunk("IDAT", first), PNG.chunk("IDAT", second)])
    assert :ok = Image.validate(png)
  end

  test "allows ancillary provenance metadata before and after pixels" do
    png =
      assemble(header(1, 1), [
        PNG.chunk("tEXt", "Source\0Synthetic fixture"),
        PNG.chunk("IDAT", :zlib.compress(<<0, 0, 0, 0, 255>>)),
        PNG.chunk("tEXt", "Description\0Original provenance")
      ])

    assert :ok = Image.validate(png)
  end

  test "validates grayscale, truecolor, indexed, grayscale alpha and 16-bit scanlines" do
    for {color, depth, row} <- [
          {0, 1, <<0>>},
          {0, 2, <<0>>},
          {0, 4, <<0>>},
          {0, 8, <<0>>},
          {0, 16, <<0, 0>>},
          {2, 8, <<0, 0, 0>>},
          {2, 16, <<0::48>>},
          {4, 8, <<0, 255>>},
          {4, 16, <<0::32>>},
          {6, 16, <<0::64>>}
        ] do
      assert :ok = Image.validate(png(1, 1, <<0, row::binary>>, color: color, depth: depth))
    end

    indexed =
      assemble(header(1, 1, color: 3, depth: 1), [
        PNG.chunk("PLTE", <<0, 0, 0, 255, 255, 255>>),
        PNG.chunk("IDAT", :zlib.compress(<<0, 0>>))
      ])

    assert :ok = Image.validate(indexed)
    assert {:error, :invalid_image} = Image.validate(png(1, 1, <<0, 0>>, color: 3, depth: 1))
  end

  test "validates Adam7 pass scanlines including tiny images" do
    # 2x2 RGBA: pass 1 is 1x1, pass 6 is 1x1, pass 7 is 2x1.
    assert :ok = Image.validate(png(2, 2, <<0, 0::32, 0, 0::32, 0, 0::64>>, interlace: 1))
    assert :ok = Image.validate(png(1, 1, <<0, 0::32>>, interlace: 1))
    assert {:error, :invalid_image} = Image.validate(png(2, 2, <<0, 0::128>>, interlace: 1))
  end

  test "rejects non-PNG values, truncation, trailing data and CRC damage" do
    valid = PNG.image()
    <<prefix::binary-size(29), byte, rest::binary>> = valid
    damaged = <<prefix::binary, Bitwise.bxor(byte, 1), rest::binary>>

    for invalid <- [
          nil,
          %{},
          [],
          "",
          <<255, 216, 255, 224>>,
          damaged,
          binary_part(valid, 0, byte_size(valid) - 1),
          valid <> "trailing"
        ] do
      assert {:error, :invalid_image} = Image.validate(invalid)
    end
  end

  test "rejects dimensions and encoded byte size above limits" do
    for {width, height} <- [{0, 1}, {1, 0}, {8193, 1}, {1, 8193}, {4001, 4000}] do
      assert {:error, :invalid_image} = Image.validate(png(width, height, <<0>>))
    end

    assert {:error, :invalid_image} = Image.validate(:binary.copy(<<0>>, 10 * 1024 * 1024 + 1))
  end

  test "rejects invalid headers and unsupported critical chunks" do
    for opts <- [[color: 1], [color: 6, depth: 4], [interlace: 2], [compression: 1], [filter: 1]] do
      assert {:error, :invalid_image} = Image.validate(png(1, 1, <<0, 0::32>>, opts))
    end

    assert {:error, :invalid_image} =
             Image.validate(assemble(header(1, 1), [PNG.chunk("WHAT", "")]))

    assert {:error, :invalid_image} =
             Image.validate(assemble(header(1, 1), [PNG.chunk("abct", "")]))
  end

  test "rejects APNG animation chunks regardless of position" do
    for type <- ["acTL", "fcTL", "fdAT"] do
      assert {:error, :invalid_image} =
               Image.validate(
                 assemble(header(1, 1), [
                   PNG.chunk(type, <<1::64>>),
                   PNG.chunk("IDAT", :zlib.compress(<<0, 0::32>>))
                 ])
               )
    end
  end

  test "requires ordered IHDR, consecutive IDAT and final empty IEND" do
    ihdr = PNG.chunk("IHDR", header(1, 1))
    idat = PNG.chunk("IDAT", :zlib.compress(<<0, 0::32>>))
    iend = PNG.chunk("IEND", "")

    for chunks <- [
          [idat, ihdr, iend],
          [ihdr, ihdr, idat, iend],
          [ihdr, iend],
          [ihdr, idat],
          [ihdr, idat, PNG.chunk("IEND", "x")],
          [ihdr, idat, PNG.chunk("tEXt", "x\0y"), PNG.chunk("IDAT", ""), iend]
        ] do
      assert {:error, :invalid_image} = Image.validate(IO.iodata_to_binary([@signature | chunks]))
    end
  end

  test "rejects bad palettes" do
    for palette <- ["", <<1>>, :binary.copy(<<0>>, 9)] do
      assert {:error, :invalid_image} =
               Image.validate(
                 assemble(header(1, 1, color: 3, depth: 1), [
                   PNG.chunk("PLTE", palette),
                   PNG.chunk("IDAT", :zlib.compress(<<0, 0>>))
                 ])
               )
    end
  end

  test "rejects wrong scanline sizes and invalid filters" do
    for raw <- ["", <<0, 0, 0, 0>>, <<0, 0::40>>, <<5, 0::32>>, <<255, 0::32>>] do
      assert {:error, :invalid_image} = Image.validate(png(1, 1, raw))
    end
  end

  test "rejects damaged or truncated zlib streams even with correct chunk CRCs" do
    compressed = :zlib.compress(<<0, 0::32>>)
    truncated = binary_part(compressed, 0, byte_size(compressed) - 1)

    for data <- ["not zlib", truncated, <<120, 156, 0, 0, 0, 0>>] do
      assert {:error, :invalid_image} =
               Image.validate(assemble(header(1, 1), [PNG.chunk("IDAT", data)]))
    end
  end

  test "ignores unused final IDAT bytes as required by the PNG decoder specification" do
    compressed = :zlib.compress(<<0, 0::32>>)

    for unused <- [<<0>>, "padding", :zlib.compress(<<0>>)] do
      assert :ok =
               Image.validate(assemble(header(1, 1), [PNG.chunk("IDAT", compressed <> unused)]))
    end

    # This is not permission for another IDAT sequence or trailing container bytes.
    assert {:error, :invalid_image} = Image.validate(PNG.image() <> <<0>>)
  end

  test "accepts widescreen image-sized PNGs while preserving opaque C2PA chunks" do
    <<signature::binary-size(8), ihdr::binary-size(25), tail::binary>> = PNG.image(1376, 768)
    metadata = PNG.chunk("caBX", "synthetic opaque provenance fixture")
    bytes = signature <> ihdr <> metadata <> tail
    assert :ok = Image.validate(bytes)
  end

  test "bounds inflation against expected scanline size" do
    bomb = :zlib.compress(:binary.copy(<<0>>, 2 * 1024 * 1024))

    assert {:error, :invalid_image} =
             Image.validate(assemble(header(1, 1), [PNG.chunk("IDAT", bomb)]))
  end

  defp png(width, height, raw, opts \\ []) do
    assemble(header(width, height, opts), [PNG.chunk("IDAT", :zlib.compress(raw))])
  end

  defp header(width, height, opts \\ []) do
    <<width::32, height::32, Keyword.get(opts, :depth, 8), Keyword.get(opts, :color, 6),
      Keyword.get(opts, :compression, 0), Keyword.get(opts, :filter, 0),
      Keyword.get(opts, :interlace, 0)>>
  end

  defp assemble(header, chunks) do
    IO.iodata_to_binary([@signature, PNG.chunk("IHDR", header), chunks, PNG.chunk("IEND", "")])
  end
end
