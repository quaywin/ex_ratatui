defmodule ExRatatui.Property.BridgePropertyTest do
  @moduledoc """
  Property-based invariants for `ExRatatui.Bridge.encode_commands!/1`,
  the funnel every render command crosses on its way to the NIF.

  These properties cover the **list-level** contract — length and
  order preservation, structural shape of the returned pairs, and the
  guarantee that obviously-malformed inputs raise — without trying to
  exhaustively validate every per-widget rule. The widget validation
  surface (~22 widgets, each with its own malformed-input shapes) is
  scheduled as its own property pass; see the `## Property tests`
  section in the Unreleased CHANGELOG for the deferred work.

  We pick a handful of "structurally simple" widgets (Paragraph with a
  string, Block, Clear, Gauge, Throbber) for the generators here so
  the properties stress the list-level encoder, not the per-widget
  encoders.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExRatatui.Bridge
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style

  alias ExRatatui.Widgets.{
    Block,
    Clear,
    Gauge,
    Paragraph,
    Throbber
  }

  # Generators -------------------------------------------------------------

  defp rect_gen do
    gen all(
          x <- integer(0..200),
          y <- integer(0..100),
          width <- integer(1..200),
          height <- integer(1..100)
        ) do
      %Rect{x: x, y: y, width: width, height: height}
    end
  end

  defp paragraph_gen do
    gen all(text <- string(:printable, max_length: 32)) do
      %Paragraph{text: text}
    end
  end

  defp block_gen do
    constant(%Block{})
  end

  defp clear_gen do
    constant(%Clear{})
  end

  defp gauge_gen do
    gen all(
          numerator <- integer(0..100),
          denominator <- integer(1..100)
        ) do
      %Gauge{ratio: (numerator / max(denominator, 1)) |> min(1.0)}
    end
  end

  defp throbber_gen do
    gen all(step <- integer(0..50)) do
      %Throbber{step: step}
    end
  end

  defp simple_widget_gen do
    one_of([
      paragraph_gen(),
      block_gen(),
      clear_gen(),
      gauge_gen(),
      throbber_gen()
    ])
  end

  defp command_gen do
    gen all(widget <- simple_widget_gen(), rect <- rect_gen()) do
      {widget, rect}
    end
  end

  # Properties: shape + length + order ------------------------------------

  describe "encode_commands!/1" do
    property "[] in, [] out" do
      check all(_ <- constant(:noop), max_runs: 5) do
        assert Bridge.encode_commands!([]) == []
      end
    end

    property "preserves length for any list of valid {widget, rect}" do
      check all(commands <- list_of(command_gen(), max_length: 8)) do
        assert length(Bridge.encode_commands!(commands)) == length(commands)
      end
    end

    property "every output element is a {map, map} pair" do
      check all(commands <- list_of(command_gen(), max_length: 8)) do
        encoded = Bridge.encode_commands!(commands)

        Enum.each(encoded, fn pair ->
          assert match?({widget_map, rect_map} when is_map(widget_map) and is_map(rect_map), pair)
        end)
      end
    end

    property "the rect_map carries the original rect's x/y/width/height" do
      check all(commands <- list_of(command_gen(), max_length: 8)) do
        encoded = Bridge.encode_commands!(commands)

        encoded
        |> Enum.zip(commands)
        |> Enum.each(fn {{_widget_map, rect_map}, {_widget, rect}} ->
          assert rect_map["x"] == rect.x
          assert rect_map["y"] == rect.y
          assert rect_map["width"] == rect.width
          assert rect_map["height"] == rect.height
        end)
      end
    end

    property "encode_commands!([cmd]) ++ encode_commands!([cmd2]) == encode_commands!([cmd, cmd2])" do
      # Concatenation distributes over encoding — equivalent to "order is
      # preserved and each command encodes independently of its siblings".
      check all(
              a <- command_gen(),
              b <- command_gen()
            ) do
        assert Bridge.encode_commands!([a]) ++ Bridge.encode_commands!([b]) ==
                 Bridge.encode_commands!([a, b])
      end
    end

    property "every widget_map carries a 'type' string identifying its widget" do
      check all(commands <- list_of(command_gen(), max_length: 8)) do
        encoded = Bridge.encode_commands!(commands)

        Enum.each(encoded, fn {widget_map, _} ->
          assert is_binary(widget_map["type"])
        end)
      end
    end
  end

  # Properties: error paths -----------------------------------------------

  describe "encode_commands!/1 error paths" do
    property "raises ArgumentError when an entry's second element isn't a Rect" do
      garbage_rect_gen =
        one_of([
          atom(:alphanumeric),
          string(:printable),
          integer(),
          map_of(string(:printable), integer(), max_length: 2)
        ])

      check all(
              widget <- simple_widget_gen(),
              not_a_rect <- garbage_rect_gen
            ) do
        assert_raise ArgumentError, fn ->
          Bridge.encode_commands!([{widget, not_a_rect}])
        end
      end
    end

    property "raises ArgumentError when an entry isn't a tuple at all" do
      garbage_entry_gen =
        one_of([
          atom(:alphanumeric),
          string(:printable),
          integer(),
          # Single-element list — definitely not a {widget, rect} tuple.
          list_of(integer(), min_length: 1, max_length: 3)
        ])

      check all(garbage <- garbage_entry_gen) do
        assert_raise ArgumentError, fn ->
          Bridge.encode_commands!([garbage])
        end
      end
    end

    property "a single garbage entry inside an otherwise-valid list still raises" do
      check all(
              before_cmds <- list_of(command_gen(), max_length: 3),
              after_cmds <- list_of(command_gen(), max_length: 3)
            ) do
        garbage = :not_a_tuple
        commands = before_cmds ++ [garbage] ++ after_cmds

        assert_raise ArgumentError, fn ->
          Bridge.encode_commands!(commands)
        end
      end
    end
  end

  # Properties: style passthrough on simple widgets -----------------------

  describe "encode_commands!/1 style passthrough" do
    property "Paragraph style modifiers survive encoding" do
      modifiers_gen =
        list_of(member_of([:bold, :dim, :italic, :underlined, :crossed_out, :reversed]),
          max_length: 4
        )

      check all(
              modifiers <- modifiers_gen,
              text <- string(:printable, max_length: 16),
              rect <- rect_gen()
            ) do
        unique = Enum.uniq(modifiers)
        paragraph = %Paragraph{text: text, style: %Style{modifiers: unique}}

        [{widget_map, _}] = Bridge.encode_commands!([{paragraph, rect}])
        encoded_mods = widget_map["style"]["modifiers"]

        assert Enum.sort(encoded_mods) == Enum.sort(Enum.map(unique, &Atom.to_string/1))
      end
    end
  end
end
