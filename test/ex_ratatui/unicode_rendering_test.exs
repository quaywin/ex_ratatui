defmodule ExRatatui.UnicodeRenderingTest do
  @moduledoc """
  Rendering regression tests for non-ASCII input across widgets.

  Exercises CJK ideographs (double-width), combining marks, zero-width-joiner
  emoji sequences, and mixed ASCII/Unicode content. The goal is to catch
  regressions where grapheme/width handling on either side of the NIF gets
  broken — these widgets should render the intended glyphs into the
  TestBackend buffer without panics, truncation, or replacement chars.

  ## A note on the buffer representation

  ratatui's `TestBackend` models a grid of cells. A double-width grapheme
  like `你` occupies two cells — the first cell holds the glyph, the second
  is a filler. When `ExRatatui.get_buffer_content/1` stringifies the buffer
  it emits `"你 "` for that pair, so `"你好世界"` comes out as `"你 好 世 界"`.
  That's the backend being faithful to the cell grid, not a rendering bug.

  Tests therefore assert grapheme-by-grapheme (via `assert_all_present/2`)
  rather than on the full joined string.
  """

  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Native
  alias ExRatatui.Widgets.{Block, List, Paragraph, Table, TextInput}

  # 4 CJK ideographs, 2 cells each = 8 cells wide
  @cjk "你好世界"
  # Mixed scripts, all double-width
  @mixed_cjk "日本語안녕你好"
  # e + combining acute accent (U+0301) = é as two codepoints, one grapheme
  @combining "cafe\u0301"
  # Woman + ZWJ + laptop — one grapheme cluster, visually one emoji
  @zwj_emoji "👩\u200D💻"
  # Family: man + ZWJ + woman + ZWJ + girl
  @zwj_family "👨\u200D👩\u200D👧"
  # BMP "emoji" (snowman, hot beverage — single codepoints)
  @bmp_emoji "☃☕"
  # Supplementary-plane emoji (surrogate-pair territory in UTF-16)
  @smp_emoji "😀🎉"

  setup do
    terminal = ExRatatui.init_test_terminal(40, 10)
    on_exit(fn -> Native.restore_terminal(terminal) end)
    %{terminal: terminal}
  end

  describe "Paragraph with CJK" do
    test "renders CJK ideographs intact", %{terminal: terminal} do
      paragraph = %Paragraph{text: @cjk}
      rect = %Rect{x: 0, y: 0, width: 40, height: 1}

      :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert_all_present(content, @cjk)
      refute content =~ "\uFFFD"
    end

    test "renders mixed ASCII + CJK", %{terminal: terminal} do
      text = "hi #{@cjk}!"
      paragraph = %Paragraph{text: text}
      rect = %Rect{x: 0, y: 0, width: 40, height: 1}

      :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert content =~ "hi"
      assert_all_present(content, @cjk)
      assert content =~ "!"
    end

    test "CJK line exactly filling width contains only those graphemes" do
      # 8 cells of CJK into an 8-wide area — after filler cells are dropped
      # the line should be exactly @cjk, no stray ASCII from bad width math.
      terminal = ExRatatui.init_test_terminal(8, 2)
      on_exit(fn -> Native.restore_terminal(terminal) end)

      paragraph = %Paragraph{text: @cjk}
      rect = %Rect{x: 0, y: 0, width: 8, height: 1}

      :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      [first_line | _] = ExRatatui.get_buffer_content(terminal) |> String.split("\n")

      assert strip_wide_fillers(first_line) == @cjk
    end

    test "multi-script CJK renders", %{terminal: terminal} do
      paragraph = %Paragraph{text: @mixed_cjk}
      rect = %Rect{x: 0, y: 0, width: 40, height: 1}

      :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert_all_present(content, @mixed_cjk)
    end
  end

  describe "Paragraph with combining marks and emoji" do
    test "combining acute accent survives rendering", %{terminal: terminal} do
      paragraph = %Paragraph{text: @combining}
      rect = %Rect{x: 0, y: 0, width: 40, height: 1}

      :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      # Both codepoints present — whether the host terminal composes them
      # visually is terminal-specific, but neither should be dropped.
      assert content =~ "cafe"
      assert content =~ "\u0301"
    end

    test "BMP emoji renders", %{terminal: terminal} do
      paragraph = %Paragraph{text: @bmp_emoji}
      rect = %Rect{x: 0, y: 0, width: 40, height: 1}

      :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert_all_present(content, @bmp_emoji)
    end

    test "SMP (supplementary-plane) emoji renders", %{terminal: terminal} do
      paragraph = %Paragraph{text: @smp_emoji}
      rect = %Rect{x: 0, y: 0, width: 40, height: 1}

      :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert_all_present(content, @smp_emoji)
    end

    test "ZWJ emoji sequence preserves the joiner", %{terminal: terminal} do
      paragraph = %Paragraph{text: @zwj_emoji}
      rect = %Rect{x: 0, y: 0, width: 40, height: 1}

      :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      # If the ZWJ is dropped the glyphs render as separate emoji.
      assert content =~ "\u200D"
      assert content =~ "👩"
      assert content =~ "💻"
    end

    test "ZWJ family sequence renders without panic", %{terminal: terminal} do
      paragraph = %Paragraph{text: "family: #{@zwj_family}"}
      rect = %Rect{x: 0, y: 0, width: 40, height: 1}

      :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert content =~ "family:"
      assert content =~ "👨"
      assert content =~ "👩"
      assert content =~ "👧"
    end
  end

  describe "Paragraph wrapping with wide chars" do
    test "CJK wraps at grapheme boundaries, not mid-codepoint" do
      # 8 cells of CJK into a 4-wide area — must wrap onto 2 lines of 2 chars
      # each. A byte-index wrap would split a codepoint and produce mojibake
      # or the replacement char.
      terminal = ExRatatui.init_test_terminal(4, 3)
      on_exit(fn -> Native.restore_terminal(terminal) end)

      paragraph = %Paragraph{text: @cjk, wrap: true}
      rect = %Rect{x: 0, y: 0, width: 4, height: 3}

      :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert_all_present(content, @cjk)
      refute content =~ "\uFFFD"
    end
  end

  describe "Block title with Unicode" do
    test "CJK title renders inside border", %{terminal: terminal} do
      block = %Block{title: @cjk, borders: [:all]}
      rect = %Rect{x: 0, y: 0, width: 20, height: 3}

      :ok = ExRatatui.draw(terminal, [{block, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert_all_present(content, @cjk)
      assert content =~ "┌"
      assert content =~ "┘"
    end

    test "emoji title renders", %{terminal: terminal} do
      block = %Block{title: "Stats 📊", borders: [:all]}
      rect = %Rect{x: 0, y: 0, width: 20, height: 3}

      :ok = ExRatatui.draw(terminal, [{block, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert content =~ "Stats"
      assert content =~ "📊"
    end
  end

  describe "List with Unicode items" do
    test "CJK items each render on their own line", %{terminal: terminal} do
      items = ["项目一", "项目二", "项目三"]
      list = %List{items: items}
      rect = %Rect{x: 0, y: 0, width: 20, height: 5}

      :ok = ExRatatui.draw(terminal, [{list, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      for item <- items, do: assert_all_present(content, item)
    end

    test "emoji items with selection highlight", %{terminal: terminal} do
      list = %List{
        items: ["✅ Done", "🚧 WIP", "⏳ Todo"],
        highlight_symbol: "▶ ",
        selected: 1
      }

      rect = %Rect{x: 0, y: 0, width: 20, height: 5}

      :ok = ExRatatui.draw(terminal, [{list, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert content =~ "▶"
      assert content =~ "🚧"
      assert content =~ "WIP"
    end
  end

  describe "Table with Unicode cells" do
    test "CJK cells render under column widths", %{terminal: terminal} do
      rows = [["张三", "三十"], ["李四", "二十五"]]
      header = ["姓名", "年龄"]

      table = %Table{
        rows: rows,
        header: header,
        widths: [{:length, 8}, {:length, 8}]
      }

      rect = %Rect{x: 0, y: 0, width: 20, height: 5}

      :ok = ExRatatui.draw(terminal, [{table, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      for cell <- header ++ Enum.concat(rows) do
        assert_all_present(content, cell)
      end
    end
  end

  describe "TextInput with Unicode" do
    test "set_value accepts CJK and renders in buffer", %{terminal: terminal} do
      state = ExRatatui.text_input_new()
      :ok = ExRatatui.text_input_set_value(state, @cjk)
      assert ExRatatui.text_input_get_value(state) == @cjk

      input = %TextInput{state: state}
      rect = %Rect{x: 0, y: 0, width: 20, height: 1}

      :ok = ExRatatui.draw(terminal, [{input, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert_all_present(content, @cjk)
    end

    test "set_value accepts emoji and round-trips", %{terminal: terminal} do
      state = ExRatatui.text_input_new()
      value = "ship it #{@smp_emoji}"
      :ok = ExRatatui.text_input_set_value(state, value)
      assert ExRatatui.text_input_get_value(state) == value

      input = %TextInput{state: state}
      rect = %Rect{x: 0, y: 0, width: 40, height: 1}

      :ok = ExRatatui.draw(terminal, [{input, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert content =~ "ship it"
      assert_all_present(content, @smp_emoji)
    end

    test "backspace on CJK removes whole grapheme", %{terminal: terminal} do
      state = ExRatatui.text_input_new()
      :ok = ExRatatui.text_input_set_value(state, @cjk)
      :ok = ExRatatui.text_input_handle_key(state, "backspace")

      expected = String.slice(@cjk, 0, 3)
      assert ExRatatui.text_input_get_value(state) == expected

      input = %TextInput{state: state}
      rect = %Rect{x: 0, y: 0, width: 20, height: 1}

      :ok = ExRatatui.draw(terminal, [{input, rect}])
      content = ExRatatui.get_buffer_content(terminal)

      assert_all_present(content, expected)
      # Last ideograph is gone
      refute content =~ "界"
    end
  end

  # -- Helpers ---------------------------------------------------------------

  # Asserts each grapheme of `text` is present somewhere in `content`.
  # Tolerates TestBackend's filler cells between wide-char pairs.
  defp assert_all_present(content, text) when is_binary(content) and is_binary(text) do
    for grapheme <- String.graphemes(text) do
      assert content =~ grapheme,
             "expected grapheme #{inspect(grapheme)} in buffer content\n\n#{content}"
    end
  end

  # Collapses `"X "` (wide grapheme + filler space) back into `"X"` so a
  # line can be compared against the source string.
  defp strip_wide_fillers(line) do
    line
    |> String.graphemes()
    |> strip_fillers([])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp strip_fillers([], acc), do: acc

  defp strip_fillers([g, " " | rest], acc) do
    if wide?(g) do
      strip_fillers(rest, [g | acc])
    else
      strip_fillers([" " | rest], [g | acc])
    end
  end

  defp strip_fillers([g | rest], acc), do: strip_fillers(rest, [g | acc])

  # A grapheme is "wide" for our purposes if any of its codepoints are in
  # the CJK/Hangul/emoji blocks that ratatui treats as double-width.
  defp wide?(grapheme) do
    grapheme
    |> String.to_charlist()
    |> Enum.any?(&wide_codepoint?/1)
  end

  defp wide_codepoint?(cp) when cp in 0x1100..0x115F, do: true
  defp wide_codepoint?(cp) when cp in 0x2E80..0x303E, do: true
  defp wide_codepoint?(cp) when cp in 0x3041..0x33FF, do: true
  defp wide_codepoint?(cp) when cp in 0x3400..0x4DBF, do: true
  defp wide_codepoint?(cp) when cp in 0x4E00..0x9FFF, do: true
  defp wide_codepoint?(cp) when cp in 0xA000..0xA4CF, do: true
  defp wide_codepoint?(cp) when cp in 0xAC00..0xD7A3, do: true
  defp wide_codepoint?(cp) when cp in 0xF900..0xFAFF, do: true
  defp wide_codepoint?(cp) when cp in 0xFE30..0xFE4F, do: true
  defp wide_codepoint?(cp) when cp in 0xFF00..0xFF60, do: true
  defp wide_codepoint?(cp) when cp in 0xFFE0..0xFFE6, do: true
  defp wide_codepoint?(cp) when cp in 0x1F300..0x1FAFF, do: true
  defp wide_codepoint?(_), do: false
end
