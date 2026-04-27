defmodule ExRatatui.Property.SessionInputPropertyTest do
  @moduledoc """
  Property-based invariants for `ExRatatui.Session.feed_input/2`, the
  ANSI/VTE input parser every byte-stream transport relies on.

  The single most important property here is **byte stitchability**: a
  parser that fragments differently when bytes arrive in two chunks
  versus one is a parser that loses keystrokes under network jitter.
  SSH packets and TCP segments split bytes at arbitrary boundaries, so
  the parser must hold partial sequences across feeds and produce the
  same event stream regardless of chunking.

  Auxiliary properties cover the simpler invariants — printable bytes
  yield one Key event, bare `0x1B` buffers, empty input yields no
  events — that the unit tests already check by hand for a few sample
  inputs but never sweep across the input space.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExRatatui.Event
  alias ExRatatui.Session

  # Generators -------------------------------------------------------------

  # Letters and digits — pure literal-character bytes that always
  # decode to a single Key event and never start a multi-byte sequence.
  defp letter_or_digit_gen do
    one_of([integer(?a..?z), integer(?A..?Z), integer(?0..?9)])
    |> map(&<<&1>>)
  end

  defp arrow_key_gen do
    member_of(["\e[A", "\e[B", "\e[C", "\e[D"])
  end

  defp function_key_gen do
    member_of(["\eOP", "\eOQ", "\eOR", "\eOS"])
  end

  defp tilde_key_gen do
    member_of(["\e[3~", "\e[5~", "\e[6~", "\e[24~"])
  end

  defp cpr_reply_gen do
    gen all(row <- integer(1..200), col <- integer(1..200)) do
      "\e[#{row};#{col}R"
    end
  end

  # A "complete" chunk: a fully-formed sequence that on its own decodes
  # cleanly. Concatenating any number of these yields a stream the
  # parser can fully drain — no leftover buffer.
  defp complete_chunk_gen do
    one_of([
      letter_or_digit_gen(),
      arrow_key_gen(),
      function_key_gen(),
      tilde_key_gen(),
      cpr_reply_gen()
    ])
  end

  defp byte_stream_gen do
    gen all(chunks <- list_of(complete_chunk_gen(), max_length: 12)) do
      Enum.join(chunks)
    end
  end

  # All non-empty splits of a binary into two halves at byte boundaries.
  # Used to assert chunking equivalence against every possible split.
  defp split_at_gen(bytes) when byte_size(bytes) > 0 do
    integer(0..byte_size(bytes))
  end

  # Helpers ----------------------------------------------------------------

  defp feed_one_chunk(bytes) do
    session = Session.new(40, 10)

    try do
      Session.feed_input(session, bytes)
    after
      Session.close(session)
    end
  end

  defp feed_split(bytes, i) do
    {prefix, suffix} = :erlang.split_binary(bytes, i)
    session = Session.new(40, 10)

    try do
      Session.feed_input(session, prefix) ++ Session.feed_input(session, suffix)
    after
      Session.close(session)
    end
  end

  defp feed_chunks(chunks) do
    session = Session.new(40, 10)

    try do
      Enum.flat_map(chunks, &Session.feed_input(session, &1))
    after
      Session.close(session)
    end
  end

  defp split_into_n(bytes, 1), do: [bytes]

  defp split_into_n(bytes, n) when n > 1 do
    size = byte_size(bytes)
    chunk_size = max(div(size, n), 1)

    bytes
    |> :erlang.binary_to_list()
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(&:erlang.list_to_binary/1)
  end

  # Properties: stitchability ---------------------------------------------

  describe "feed_input/2 stitchability" do
    property "splitting at any single byte boundary preserves the event sequence" do
      check all(
              bytes <- byte_stream_gen(),
              bytes != "",
              i <- split_at_gen(bytes)
            ) do
        whole = feed_one_chunk(bytes)
        split = feed_split(bytes, i)

        assert whole == split
      end
    end

    property "splitting into N chunks preserves the event sequence" do
      check all(
              bytes <- byte_stream_gen(),
              bytes != "",
              n <- integer(2..5)
            ) do
        whole = feed_one_chunk(bytes)
        chunks = split_into_n(bytes, n)
        chunked = feed_chunks(chunks)

        assert whole == chunked
      end
    end

    property "byte-by-byte feeding is equivalent to feeding the whole stream" do
      check all(bytes <- byte_stream_gen()) do
        whole = feed_one_chunk(bytes)

        per_byte_chunks = for <<b <- bytes>>, do: <<b>>
        per_byte = feed_chunks(per_byte_chunks)

        assert whole == per_byte
      end
    end
  end

  # Properties: shape of the event stream ---------------------------------

  describe "feed_input/2 event shape" do
    property "empty input produces no events" do
      check all(_ <- constant(:noop), max_runs: 5) do
        assert feed_one_chunk("") == []
      end
    end

    property "any single letter or digit yields exactly one Key press" do
      check all(byte <- letter_or_digit_gen()) do
        assert [%Event.Key{kind: "press"}] = feed_one_chunk(byte)
      end
    end

    property "bare 0x1B buffers and produces no events" do
      check all(_ <- constant(:noop), max_runs: 5) do
        assert feed_one_chunk(<<0x1B>>) == []
      end
    end

    property "every arrow key yields exactly one Key press" do
      check all(seq <- arrow_key_gen()) do
        assert [%Event.Key{kind: "press"}] = feed_one_chunk(seq)
      end
    end

    property "concatenating two complete chunks emits the union of their events in order" do
      check all(
              a <- complete_chunk_gen(),
              b <- complete_chunk_gen()
            ) do
        events_a = feed_one_chunk(a)
        events_b = feed_one_chunk(b)
        events_ab = feed_one_chunk(a <> b)

        assert events_ab == events_a ++ events_b
      end
    end

    property "every event from byte_stream_gen is non-nil and structurally sound" do
      check all(bytes <- byte_stream_gen()) do
        events = feed_one_chunk(bytes)

        Enum.each(events, fn ev ->
          # Every event we generate is one of the three known types.
          assert match?(%Event.Key{}, ev) or match?(%Event.Resize{}, ev) or
                   match?(%Event.Mouse{}, ev),
                 "unexpected event shape: #{inspect(ev)}"
        end)
      end
    end
  end
end
