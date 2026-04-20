defmodule ExRatatui.Property.StylePropertyTest do
  @moduledoc """
  Property-based invariants for style encoding across the bridge.

  Any `%Style{}` built from the types declared in `ExRatatui.Style` should
  survive `Bridge.encode_commands!/1` (the wire-format producer) and a
  subsequent `draw/2` into a test terminal — no `ArgumentError` from
  `encode_color/1` or panic from the Rust side.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExRatatui.Bridge
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Native
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph

  @named_colors ~w(
    black red green yellow blue magenta cyan gray
    dark_gray light_red light_green light_yellow light_blue
    light_magenta light_cyan white reset
  )a

  @modifiers ~w(bold dim italic underlined crossed_out reversed)a

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
          modifiers <- list_of(member_of(@modifiers), max_length: 6)
        ) do
      %Style{fg: fg, bg: bg, modifiers: Enum.uniq(modifiers)}
    end
  end

  # Properties -------------------------------------------------------------

  property "any valid style encodes without raising" do
    check all(style <- style_gen()) do
      paragraph = %Paragraph{text: "hello", style: style}
      rect = %Rect{x: 0, y: 0, width: 10, height: 1}

      [{widget_map, _rect_map}] = Bridge.encode_commands!([{paragraph, rect}])

      assert is_map(widget_map["style"])
      assert is_list(widget_map["style"]["modifiers"])
    end
  end

  property "encoded style preserves modifier set" do
    check all(modifiers <- list_of(member_of(@modifiers), max_length: 6)) do
      unique = Enum.uniq(modifiers)
      style = %Style{modifiers: unique}
      paragraph = %Paragraph{text: "x", style: style}
      rect = %Rect{x: 0, y: 0, width: 5, height: 1}

      [{widget_map, _}] = Bridge.encode_commands!([{paragraph, rect}])
      encoded = widget_map["style"]["modifiers"]

      assert Enum.sort(encoded) == Enum.sort(Enum.map(unique, &Atom.to_string/1))
    end
  end

  property "nil fg/bg are omitted from encoded style" do
    check all(modifiers <- list_of(member_of(@modifiers), max_length: 3)) do
      style = %Style{fg: nil, bg: nil, modifiers: Enum.uniq(modifiers)}
      paragraph = %Paragraph{text: "x", style: style}
      rect = %Rect{x: 0, y: 0, width: 5, height: 1}

      [{widget_map, _}] = Bridge.encode_commands!([{paragraph, rect}])
      encoded = widget_map["style"]

      refute Map.has_key?(encoded, "fg")
      refute Map.has_key?(encoded, "bg")
    end
  end

  property "any valid style renders through TestBackend without crashing" do
    terminal = ExRatatui.init_test_terminal(20, 3)
    on_exit(fn -> Native.restore_terminal(terminal) end)

    check all(style <- style_gen()) do
      paragraph = %Paragraph{text: "hi", style: style}
      rect = %Rect{x: 0, y: 0, width: 20, height: 1}

      assert :ok = ExRatatui.draw(terminal, [{paragraph, rect}])
      content = ExRatatui.get_buffer_content(terminal)
      assert content =~ "hi"
    end
  end
end
