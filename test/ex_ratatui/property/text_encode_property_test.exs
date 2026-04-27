defmodule ExRatatui.Property.TextEncodePropertyTest do
  @moduledoc """
  Property-based invariants for `ExRatatui.Text.Encode`, the wire-format
  producer that feeds `%Text{}` and `%Line{}` values to the NIF.

  These properties cover the structural promises of the encoder — the
  shape of the wire map, line/span count preservation, content
  passthrough, and alignment serialization — that the NIF relies on.
  Style encoding itself is exercised by `ExRatatui.Property.StylePropertyTest`;
  here we only sanity-check that styles round-trip through the
  `Text → wire` boundary.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExRatatui.Style
  alias ExRatatui.Text
  alias ExRatatui.Text.Encode
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @named_colors ~w(
    black red green yellow blue magenta cyan gray
    dark_gray light_red light_green light_yellow light_blue
    light_magenta light_cyan white reset
  )a

  @modifiers ~w(bold dim italic underlined crossed_out reversed)a

  @alignments [:left, :center, :right]

  # Generators -------------------------------------------------------------

  defp color_gen do
    one_of([
      constant(nil),
      member_of(@named_colors),
      gen all(r <- integer(0..255), g <- integer(0..255), b <- integer(0..255)) do
        {:rgb, r, g, b}
      end,
      gen all(i <- integer(0..255)) do
        {:indexed, i}
      end
    ])
  end

  defp style_gen do
    gen all(
          fg <- color_gen(),
          bg <- color_gen(),
          modifiers <- list_of(member_of(@modifiers), max_length: 4)
        ) do
      %Style{fg: fg, bg: bg, modifiers: Enum.uniq(modifiers)}
    end
  end

  defp alignment_gen, do: one_of([constant(nil), member_of(@alignments)])

  defp span_gen do
    gen all(
          content <- string(:printable, max_length: 24),
          style <- style_gen()
        ) do
      %Span{content: content, style: style}
    end
  end

  defp line_gen do
    gen all(
          spans <- list_of(span_gen(), max_length: 5),
          style <- style_gen(),
          alignment <- alignment_gen()
        ) do
      %Line{spans: spans, style: style, alignment: alignment}
    end
  end

  defp text_gen do
    gen all(
          lines <- list_of(line_gen(), max_length: 5),
          style <- style_gen(),
          alignment <- alignment_gen()
        ) do
      %Text{lines: lines, style: style, alignment: alignment}
    end
  end

  # Properties: to_wire_text! ----------------------------------------------

  describe "to_wire_text!/1" do
    property "returns a map with required keys regardless of input shape" do
      check all(text <- text_gen()) do
        wire = Encode.to_wire_text!(text)

        assert is_map(wire)
        assert is_list(wire["lines"])
        assert is_map(wire["style"])
        assert is_list(wire["style"]["modifiers"])
      end
    end

    property "preserves line count" do
      check all(text <- text_gen()) do
        wire = Encode.to_wire_text!(text)
        assert length(wire["lines"]) == length(text.lines)
      end
    end

    property "preserves span content for every span on every line" do
      check all(text <- text_gen()) do
        wire = Encode.to_wire_text!(text)

        wire["lines"]
        |> Enum.zip(text.lines)
        |> Enum.each(fn {wire_line, %Line{spans: spans}} ->
          encoded_contents = Enum.map(wire_line["spans"], & &1["content"])
          original_contents = Enum.map(spans, & &1.content)
          assert encoded_contents == original_contents
        end)
      end
    end

    property "preserves span count for every line" do
      check all(text <- text_gen()) do
        wire = Encode.to_wire_text!(text)

        wire["lines"]
        |> Enum.zip(text.lines)
        |> Enum.each(fn {wire_line, line} ->
          assert length(wire_line["spans"]) == length(line.spans)
        end)
      end
    end

    property "alignment is omitted when nil and present otherwise" do
      check all(
              lines <- list_of(line_gen(), max_length: 3),
              style <- style_gen(),
              alignment <- alignment_gen()
            ) do
        text = %Text{lines: lines, style: style, alignment: alignment}
        wire = Encode.to_wire_text!(text)

        case alignment do
          nil -> refute Map.has_key?(wire, "alignment")
          a -> assert wire["alignment"] == Atom.to_string(a)
        end
      end
    end

    property "agrees with to_wire_line!/1 on a per-line basis" do
      check all(text <- text_gen()) do
        wire = Encode.to_wire_text!(text)
        per_line = Enum.map(text.lines, &Encode.to_wire_line!/1)
        assert wire["lines"] == per_line
      end
    end
  end

  # Properties: to_wire_line! ----------------------------------------------

  describe "to_wire_line!/1" do
    property "returns a map carrying spans + style for any line" do
      check all(line <- line_gen()) do
        wire = Encode.to_wire_line!(line)

        assert is_map(wire)
        assert is_list(wire["spans"])
        assert is_map(wire["style"])
        assert length(wire["spans"]) == length(line.spans)
      end
    end

    property "preserves span content" do
      check all(line <- line_gen()) do
        wire = Encode.to_wire_line!(line)
        encoded = Enum.map(wire["spans"], & &1["content"])
        original = Enum.map(line.spans, & &1.content)
        assert encoded == original
      end
    end

    property "alignment is omitted when nil and present otherwise" do
      check all(
              spans <- list_of(span_gen(), max_length: 3),
              style <- style_gen(),
              alignment <- alignment_gen()
            ) do
        line = %Line{spans: spans, style: style, alignment: alignment}
        wire = Encode.to_wire_line!(line)

        case alignment do
          nil -> refute Map.has_key?(wire, "alignment")
          a -> assert wire["alignment"] == Atom.to_string(a)
        end
      end
    end
  end
end
