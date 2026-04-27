defmodule ExRatatui.Property.ByteStreamPropertyTest do
  @moduledoc """
  Property-based invariants for `ExRatatui.Transport.ByteStream`, the
  byte-pump every byte-stream transport (SSH today, custom TCP, future
  Kino) routes input through.

  The contract `forward_input/3` advertises:

    1. Every event the parser emits is dispatched to the server.
    2. Resize events (from a CPR reply or similar) are absorbed into
       `{:ex_ratatui_resize, w, h}` notifications and are *never*
       forwarded as plain `{:ex_ratatui_event, %Event.Resize{}}`.
    3. Non-resize events fan out as `{:ex_ratatui_event, event}`.
    4. The function returns the parsed event list so callers can
       inspect it (e.g. SSH uses an empty result + `0x1B` to arm its
       bare-Esc timeout) without re-parsing.

  These properties drive random byte streams (printable ASCII,
  CSI key sequences, and CPR resize replies) through the helper and
  verify all four invariants hold for arbitrary order, length, and
  chunking.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExRatatui.Event
  alias ExRatatui.Session
  alias ExRatatui.Transport.ByteStream

  # Generators -------------------------------------------------------------

  # Printable, non-escape, non-control bytes — each one decodes to a
  # single Key event.
  defp printable_byte_gen do
    one_of([
      integer(0x20..0x7E),
      # Letters and digits exercise the canonical "literal char" path.
      integer(?a..?z),
      integer(?A..?Z),
      integer(?0..?9)
    ])
    |> map(&<<&1>>)
  end

  # Well-formed CSI cursor key sequences — atomic, no buffering
  # complications.
  defp arrow_key_gen do
    member_of(["\e[A", "\e[B", "\e[C", "\e[D"])
  end

  # CPR response sequence: `\e[<row>;<col>R`. The parser decodes this
  # into an `%Event.Resize{}` whose dimensions are derived from the
  # row/col answer (see `lib/ex_ratatui/ssh.ex` for how this is used).
  defp cpr_reply_gen do
    gen all(row <- integer(1..200), col <- integer(1..200)) do
      "\e[#{row};#{col}R"
    end
  end

  # A single "byte-stream chunk" — anything `feed_input/2` can swallow
  # without dropping bytes mid-sequence.
  defp chunk_gen do
    one_of([
      printable_byte_gen(),
      arrow_key_gen(),
      cpr_reply_gen()
    ])
  end

  defp byte_stream_gen do
    gen all(chunks <- list_of(chunk_gen(), max_length: 12)) do
      Enum.join(chunks)
    end
  end

  # Helpers ----------------------------------------------------------------

  defp drain_inbox(acc \\ []) do
    receive do
      {:ex_ratatui_event, _} = msg -> drain_inbox([msg | acc])
      {:ex_ratatui_resize, _, _} = msg -> drain_inbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp non_resize?(%Event.Resize{}), do: false
  defp non_resize?(_), do: true

  # Properties -------------------------------------------------------------

  describe "forward_input/3" do
    property "no Event.Resize ever leaks as a :ex_ratatui_event" do
      check all(bytes <- byte_stream_gen()) do
        session = Session.new(80, 24)
        on_exit(fn -> Session.close(session) end)

        _ = ByteStream.forward_input(session, self(), bytes)

        for msg <- drain_inbox() do
          refute match?({:ex_ratatui_event, %Event.Resize{}}, msg)
        end
      end
    end

    property "every parsed event is delivered to the server in order" do
      check all(bytes <- byte_stream_gen()) do
        session = Session.new(80, 24)
        on_exit(fn -> Session.close(session) end)

        events = ByteStream.forward_input(session, self(), bytes)
        messages = drain_inbox()

        # One message per parsed event — Resize events become resize
        # notifications, everything else becomes an event message, but
        # the count must still match.
        assert length(messages) == length(events)

        # Order is preserved: zip and verify each pair.
        events
        |> Enum.zip(messages)
        |> Enum.each(fn
          {%Event.Resize{width: w, height: h}, msg} ->
            assert msg == {:ex_ratatui_resize, w, h}

          {event, msg} ->
            assert msg == {:ex_ratatui_event, event}
        end)
      end
    end

    property "non-Resize events arrive as :ex_ratatui_event with identical payloads" do
      check all(bytes <- byte_stream_gen()) do
        session = Session.new(80, 24)
        on_exit(fn -> Session.close(session) end)

        events = ByteStream.forward_input(session, self(), bytes)
        messages = drain_inbox()

        non_resize_events = Enum.filter(events, &non_resize?/1)

        non_resize_msgs =
          Enum.flat_map(messages, fn
            {:ex_ratatui_event, ev} -> [ev]
            _ -> []
          end)

        assert non_resize_events == non_resize_msgs
      end
    end

    property "Resize events become :ex_ratatui_resize with matching dimensions" do
      check all(bytes <- byte_stream_gen()) do
        session = Session.new(80, 24)
        on_exit(fn -> Session.close(session) end)

        events = ByteStream.forward_input(session, self(), bytes)
        messages = drain_inbox()

        resize_events =
          Enum.flat_map(events, fn
            %Event.Resize{} = r -> [{r.width, r.height}]
            _ -> []
          end)

        resize_msgs =
          Enum.flat_map(messages, fn
            {:ex_ratatui_resize, w, h} -> [{w, h}]
            _ -> []
          end)

        assert resize_events == resize_msgs
      end
    end

    property "returns the same events that feed_input/2 would alone" do
      check all(bytes <- byte_stream_gen()) do
        session_a = Session.new(80, 24)
        session_b = Session.new(80, 24)

        on_exit(fn ->
          Session.close(session_a)
          Session.close(session_b)
        end)

        from_helper = ByteStream.forward_input(session_a, self(), bytes)
        from_native = Session.feed_input(session_b, bytes)

        # Drain our own mailbox so subsequent properties don't see leftovers.
        _ = drain_inbox()

        assert from_helper == from_native
      end
    end
  end

  # Properties: forward_resize/4 -------------------------------------------

  describe "forward_resize/4" do
    property "always sends :ex_ratatui_resize with the requested dimensions" do
      check all(
              w <- integer(1..400),
              h <- integer(1..200)
            ) do
        session = Session.new(80, 24)
        on_exit(fn -> Session.close(session) end)

        assert :ok = ByteStream.forward_resize(session, self(), w, h)

        assert_received {:ex_ratatui_resize, ^w, ^h}
        # Drain anything else so this test is hermetic.
        _ = drain_inbox()
      end
    end
  end
end
