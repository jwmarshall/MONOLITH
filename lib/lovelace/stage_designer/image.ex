defmodule Lovelace.StageDesigner.Image do
  @moduledoc "Validates bounded PNG/JPEG imagery without changing bytes or provenance metadata."

  alias Lovelace.StageDesigner.JPEG

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @max_bytes 10 * 1024 * 1024
  @adam7 [
    {0, 0, 8, 8},
    {4, 0, 8, 8},
    {0, 4, 4, 8},
    {2, 0, 4, 4},
    {0, 2, 2, 4},
    {1, 0, 2, 2},
    {0, 1, 1, 2}
  ]

  def format(<<@signature, _rest::binary>>), do: :png
  def format(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: :jpeg
  def format(_bytes), do: :unknown

  def extension(:png), do: "png"
  def extension(:jpeg), do: "jpg"
  def extension(_format), do: nil

  def mime_type(:png), do: "image/png"
  def mime_type(:jpeg), do: "image/jpeg"
  def mime_type(_format), do: nil

  @spec validate(term()) :: :ok | {:error, :invalid_image}
  def validate(<<0xFF, 0xD8, _rest::binary>> = bytes),
    do: JPEG.validate(bytes)

  def validate(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    <<@signature, 13::32, "IHDR", header::binary-size(13), crc::32, rest::binary>> = bytes
    true = :erlang.crc32(["IHDR", header]) == crc
    info = header!(header)
    compressed = chunks!(rest, info, %{palette: false, phase: :before, data: [], count: 0})
    validate_pixels!(compressed, scanlines(info))
    :ok
  rescue
    _ -> {:error, :invalid_image}
  catch
    _, _ -> {:error, :invalid_image}
  end

  def validate(_), do: {:error, :invalid_image}

  defp header!(<<width::32, height::32, depth, color, 0, 0, interlace>>) do
    true = width in 1..8192 and height in 1..8192 and width * height <= 16_000_000
    true = interlace in [0, 1]

    {channels, depths} =
      case color do
        0 -> {1, [1, 2, 4, 8, 16]}
        2 -> {3, [8, 16]}
        3 -> {1, [1, 2, 4, 8]}
        4 -> {2, [8, 16]}
        6 -> {4, [8, 16]}
      end

    true = depth in depths

    %{
      width: width,
      height: height,
      depth: depth,
      color: color,
      bits: channels * depth,
      interlace: interlace
    }
  end

  defp chunks!(<<length::32, type::binary-size(4), rest::binary>>, info, state)
       when length <= @max_bytes and state.count < 4096 do
    <<data::binary-size(^length), crc::32, tail::binary>> = rest
    true = valid_type?(type) and :erlang.crc32([type, data]) == crc
    chunk!(type, data, tail, info, %{state | count: state.count + 1})
  end

  defp valid_type?(<<a, b, c, d>>) do
    Enum.all?([a, b, c, d], &(&1 in ?A..?Z or &1 in ?a..?z)) and c in ?A..?Z
  end

  defp chunk!("IEND", "", "", info, state) when state.phase != :before do
    true = info.color != 3 or state.palette
    true = Enum.any?(state.data, &(byte_size(&1) > 0))
    Enum.reverse(state.data)
  end

  defp chunk!("PLTE", data, tail, info, %{phase: :before, palette: false} = state) do
    true = info.color not in [0, 4]
    true = byte_size(data) in 3..768 and rem(byte_size(data), 3) == 0
    true = info.color != 3 or div(byte_size(data), 3) <= Bitwise.bsl(1, info.depth)
    chunks!(tail, info, %{state | palette: true})
  end

  defp chunk!("IDAT", data, tail, info, state) when state.phase != :after do
    true = info.color != 3 or state.palette
    chunks!(tail, info, %{state | phase: :during, data: [data | state.data]})
  end

  defp chunk!(type, _data, tail, info, state) do
    # Unknown critical chunks and all APNG animation chunks are outside this policy.
    <<first, _::binary>> = type
    true = first in ?a..?z and type not in ["acTL", "fcTL", "fdAT"]
    phase = if state.phase == :during, do: :after, else: state.phase
    chunks!(tail, info, %{state | phase: phase})
  end

  defp scanlines(%{interlace: 0} = info), do: [{row_bytes(info.width, info.bits), info.height}]

  defp scanlines(info) do
    for {x, y, dx, dy} <- @adam7,
        width = pass_size(info.width, x, dx),
        height = pass_size(info.height, y, dy),
        width > 0 and height > 0 do
      {row_bytes(width, info.bits), height}
    end
  end

  defp row_bytes(width, bits), do: div(width * bits + 7, 8)
  defp pass_size(size, start, step), do: max(0, div(size - start + step - 1, step))

  defp validate_pixels!(compressed, passes) do
    stream = :zlib.open()

    try do
      # Use OTP's documented initializer. PNG section 11.2.3 tells decoders to
      # ignore unused bytes after the zlib stream in the final IDAT chunk.
      # Container CRC/order, exact scanlines, and completed zlib stream still apply.
      :ok = :zlib.inflateInit(stream, 15)
      # safeInflate bounds each output allocation, including for compression bombs.
      {[], :filter} = inflate!(stream, :zlib.safeInflate(stream, compressed), {passes, :filter})
      # Unlike safeInflate's :finished, inflateEnd also proves the zlib stream ended.
      :ok = :zlib.inflateEnd(stream)
    after
      :zlib.close(stream)
    end
  end

  defp inflate!(stream, {status, output}, state) when status in [:continue, :finished] do
    {passes, remaining} = state
    state = scan!(IO.iodata_to_binary(output), passes, remaining)

    case status do
      :continue -> inflate!(stream, :zlib.safeInflate(stream, []), state)
      :finished -> state
    end
  end

  defp scan!("", passes, remaining), do: {passes, remaining}

  defp scan!(<<filter, rest::binary>>, [{row_bytes, _} | _] = passes, :filter)
       when filter in 0..4 do
    scan!(rest, passes, row_bytes)
  end

  defp scan!(data, [{row_bytes, rows} | tail] = passes, remaining)
       when is_integer(remaining) do
    if byte_size(data) < remaining do
      {passes, remaining - byte_size(data)}
    else
      <<_::binary-size(^remaining), rest::binary>> = data
      next = if rows == 1, do: tail, else: [{row_bytes, rows - 1} | tail]
      scan!(rest, next, :filter)
    end
  end
end
