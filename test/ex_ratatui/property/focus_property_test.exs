defmodule ExRatatui.Property.FocusPropertyTest do
  @moduledoc """
  Property-based invariants for `ExRatatui.Focus`.

  `Focus` is a ring over an ordered, unique list of atom IDs. The core
  invariants are:

    * `current/1` always returns an ID that was registered.
    * `next` and `prev` are inverses.
    * N applications of `next` on a ring of length N returns to the origin.
    * `handle_key/2` with a next/prev key is equivalent to `next/1` or `prev/1`
      and consumes the event; any other key passes through unchanged.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExRatatui.Event
  alias ExRatatui.Focus

  # Generators -------------------------------------------------------------

  # Small, closed alphabet — keeps uniqueness easy and shrink useful.
  @alphabet ~w(a b c d e f g h)a

  defp ids_gen do
    gen all(
          size <- integer(1..length(@alphabet)),
          picks <-
            @alphabet
            |> Enum.take(length(@alphabet))
            |> Enum.shuffle()
            |> Enum.take(size)
            |> constant()
        ) do
      picks
    end
  end

  defp focus_gen do
    gen all(ids <- ids_gen()) do
      Focus.new(ids)
    end
  end

  # Properties -------------------------------------------------------------

  property "current/1 is always a registered ID" do
    check all(focus <- focus_gen()) do
      assert Focus.current(focus) in focus.ids
    end
  end

  property "next ∘ prev == identity" do
    check all(focus <- focus_gen()) do
      assert focus |> Focus.next() |> Focus.prev() == focus
      assert focus |> Focus.prev() |> Focus.next() == focus
    end
  end

  property "N applications of next cycle back to start" do
    check all(focus <- focus_gen()) do
      n = length(focus.ids)
      cycled = Enum.reduce(1..n, focus, fn _, f -> Focus.next(f) end)
      assert cycled == focus
    end
  end

  property "N applications of prev cycle back to start" do
    check all(focus <- focus_gen()) do
      n = length(focus.ids)
      cycled = Enum.reduce(1..n, focus, fn _, f -> Focus.prev(f) end)
      assert cycled == focus
    end
  end

  property "focus/2 to any registered ID makes it current" do
    check all(focus <- focus_gen(), chosen <- member_of(focus.ids)) do
      assert Focus.focused?(Focus.focus(focus, chosen), chosen)
    end
  end

  property "arbitrary next/prev sequence keeps current inside the ring" do
    check all(
            focus <- focus_gen(),
            steps <- list_of(member_of([:next, :prev]), max_length: 20)
          ) do
      final =
        Enum.reduce(steps, focus, fn
          :next, f -> Focus.next(f)
          :prev, f -> Focus.prev(f)
        end)

      assert Focus.current(final) in focus.ids
    end
  end

  property "handle_key with default Tab advances focus and consumes event" do
    check all(focus <- focus_gen()) do
      event = %Event.Key{code: "tab", modifiers: [], kind: :press}
      assert {moved, nil} = Focus.handle_key(focus, event)
      assert moved == Focus.next(focus)
    end
  end

  property "handle_key with default Shift+Tab retreats focus" do
    check all(focus <- focus_gen()) do
      event = %Event.Key{code: "tab", modifiers: ["shift"], kind: :press}
      assert {moved, nil} = Focus.handle_key(focus, event)
      assert moved == Focus.prev(focus)
    end
  end

  property "handle_key with back_tab also retreats focus" do
    check all(focus <- focus_gen()) do
      event = %Event.Key{code: "back_tab", modifiers: [], kind: :press}
      assert {moved, nil} = Focus.handle_key(focus, event)
      assert moved == Focus.prev(focus)
    end
  end

  property "handle_key with unrelated key passes through unchanged" do
    check all(
            focus <- focus_gen(),
            code <- member_of(~w(enter esc left right up down a b 1 space))
          ) do
      event = %Event.Key{code: code, modifiers: [], kind: :press}
      assert {^focus, ^event} = Focus.handle_key(focus, event)
    end
  end

  property "custom next_keys match regardless of modifier order" do
    check all(focus <- focus_gen()) do
      focus =
        Focus.new(focus.ids,
          next_keys: [%Event.Key{code: "right", modifiers: ["ctrl", "shift"]}]
        )

      # Same modifier set, reversed order — should still match.
      event = %Event.Key{code: "right", modifiers: ["shift", "ctrl"], kind: :press}
      assert {moved, nil} = Focus.handle_key(focus, event)
      assert moved == Focus.next(focus)
    end
  end
end
