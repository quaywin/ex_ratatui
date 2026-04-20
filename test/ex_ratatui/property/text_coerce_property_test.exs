defmodule ExRatatui.Property.TextCoercePropertyTest do
  @moduledoc """
  Property-based invariants for `ExRatatui.Text.Coerce`.

  `coerce_text!/1` normalizes any accepted shape into a `%Text{}`. It should
  be idempotent, preserve line content for string inputs, and never drop
  spans/lines.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExRatatui.Text
  alias ExRatatui.Text.{Coerce, Line, Span}

  # Generators -------------------------------------------------------------

  # Printable ASCII without newlines — newlines have special split semantics
  # handled in a dedicated property below.
  defp safe_binary_gen do
    string(?\s..?~, min_length: 0, max_length: 30)
  end

  defp span_gen do
    gen all(content <- safe_binary_gen()) do
      %Span{content: content}
    end
  end

  defp line_gen do
    gen all(spans <- list_of(span_gen(), max_length: 4)) do
      %Line{spans: spans}
    end
  end

  # Properties -------------------------------------------------------------

  property "coerce_text! is idempotent" do
    check all(
            input <-
              one_of([
                safe_binary_gen(),
                span_gen(),
                line_gen(),
                list_of(line_gen(), max_length: 4),
                list_of(span_gen(), max_length: 4)
              ])
          ) do
      once = Coerce.coerce_text!(input)
      twice = Coerce.coerce_text!(once)
      assert once == twice
    end
  end

  property "coerce_text! on a binary preserves every line's content" do
    check all(s <- string(:printable, max_length: 80)) do
      %Text{lines: lines} = Coerce.coerce_text!(s)
      expected_chunks = String.split(s, "\n")

      assert length(lines) == length(expected_chunks)

      Enum.zip(lines, expected_chunks)
      |> Enum.each(fn {%Line{spans: [%Span{content: content}]}, chunk} ->
        assert content == chunk
      end)
    end
  end

  property "coerce_text! on a %Span{} yields exactly one line with that span" do
    check all(span <- span_gen()) do
      assert %Text{lines: [%Line{spans: [^span]}]} = Coerce.coerce_text!(span)
    end
  end

  property "coerce_text! on a list of spans yields one line with all spans" do
    check all(spans <- list_of(span_gen(), min_length: 1, max_length: 5)) do
      assert %Text{lines: [%Line{spans: ^spans}]} = Coerce.coerce_text!(spans)
    end
  end

  property "coerce_text! on a list of lines preserves them" do
    check all(lines <- list_of(line_gen(), min_length: 1, max_length: 5)) do
      assert %Text{lines: ^lines} = Coerce.coerce_text!(lines)
    end
  end

  property "coerce_line! on a newline-free binary always produces one span with the value" do
    check all(s <- safe_binary_gen()) do
      assert %Line{spans: [%Span{content: ^s}]} = Coerce.coerce_line!(s)
    end
  end

  property "coerce_line! rejects binaries containing a newline" do
    check all(
            prefix <- safe_binary_gen(),
            suffix <- safe_binary_gen()
          ) do
      assert_raise ArgumentError, fn -> Coerce.coerce_line!("#{prefix}\n#{suffix}") end
    end
  end
end
