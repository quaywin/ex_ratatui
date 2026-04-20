defmodule ExRatatui.CrossTransportTest do
  @moduledoc """
  Cross-transport parity: the same App module must produce the same
  widget tree whether it's mounted locally, over SSH, or over Erlang
  distribution.

  Tagged `:distributed` because the distributed branch requires a named
  Erlang node. Run with:

      elixir --sname test -S mix test --only distributed

  The shared App (`ExRatatui.Test.CrossTransportApp`) sends every
  rendered widget list back to the test process, so we can compare
  trees from all three transports without relying on transport-specific
  byte streams.
  """

  use ExUnit.Case

  @moduletag :distributed
  @moduletag :tmp_dir
  # SSH handshake emits debug logs and teardown races produce warnings
  # like `ExRatatui.SSH writer failed: :closed`. Buffer them — ExUnit
  # will only replay on failure.
  @moduletag capture_log: true

  alias ExRatatui.Distributed.Listener
  alias ExRatatui.Layout.Rect
  alias ExRatatui.SSH.Daemon
  alias ExRatatui.Test.CrossTransportApp

  @app CrossTransportApp
  @width 80
  @height 24

  setup %{tmp_dir: tmp_dir} do
    unless Node.alive?() do
      flunk(
        "Node is not distributed. " <>
          "Run with: elixir --sname test -S mix test --only distributed"
      )
    end

    # -- Peer node for the distributed branch ------------------------------
    code_paths =
      Path.wildcard("_build/test/lib/*/ebin") ++
        Path.wildcard("#{:code.lib_dir(:elixir)}/ebin")

    args = Enum.flat_map(code_paths, fn path -> [~c"-pa", String.to_charlist(path)] end)
    peer_name = :"cross_#{System.unique_integer([:positive])}"
    {:ok, peer_pid, peer_node} = :peer.start(%{name: peer_name, args: args})
    on_exit(fn -> :peer.stop(peer_pid) end)

    # -- tmp host key for the SSH branch -----------------------------------
    system_dir = Path.join(tmp_dir, "system")
    File.mkdir_p!(system_dir)
    generate_host_key!(system_dir)

    {:ok, peer_node: peer_node, system_dir: String.to_charlist(system_dir)}
  end

  test "same App renders identical widget tree across local, SSH, and distributed", ctx do
    local_tree = render_once_local()
    ssh_tree = render_once_ssh(ctx.system_dir)
    dist_tree = render_once_distributed(ctx.peer_node)

    # Primary assertion: trees are identical across all three transports.
    assert local_tree == ssh_tree,
           "local vs ssh diverged:\nlocal: #{inspect(local_tree)}\nssh:   #{inspect(ssh_tree)}"

    assert ssh_tree == dist_tree,
           "ssh vs distributed diverged:\nssh:  #{inspect(ssh_tree)}\ndist: #{inspect(dist_tree)}"

    # Sanity on shape — the App renders two widgets at full width.
    assert [
             {%ExRatatui.Widgets.Block{title: "cross-transport"},
              %Rect{width: @width, height: @height}},
             {%ExRatatui.Widgets.Paragraph{text: "count: 0"}, _inner}
           ] = local_tree
  end

  test "event round-trip produces the same next widget tree over SSH and distributed", ctx do
    # Local is excluded here — its event flow is NIF polling from a real
    # (or test-backed) terminal, not mailbox messages, so events can't
    # be injected from a test without a public seam. SSH and distributed
    # both dispatch events as `{:ex_ratatui_event, _}` messages, so if
    # the App produces matching trees for one key press we've shown the
    # two transports agree on App semantics.

    event = %ExRatatui.Event.Key{code: "a", modifiers: [], kind: :press}

    ssh_after = render_ssh_after_event(ctx.system_dir, event)
    dist_after = render_distributed_after_event(ctx.peer_node, event)

    assert ssh_after == dist_after
    assert [_, {%ExRatatui.Widgets.Paragraph{text: "count: 1"}, _}] = ssh_after
  end

  ## Per-transport drivers -----------------------------------------------

  defp render_once_local do
    test_pid = self()

    {:ok, server} =
      ExRatatui.Server.start_link(
        mod: @app,
        test_mode: {@width, @height},
        test_pid: test_pid
      )

    # mount fires on the test process; first render is synchronous in init.
    assert_receive {:mounted, ^server}, 2000
    assert_receive {:rendered, ^server, widgets}, 2000

    ref = Process.monitor(server)
    GenServer.stop(server)
    assert_receive {:DOWN, ^ref, :process, ^server, _}, 2000

    drain()
    widgets
  end

  defp render_once_ssh(system_dir) do
    test_pid = self()

    {:ok, daemon} =
      Daemon.start_link(
        mod: @app,
        name: nil,
        port: 0,
        system_dir: system_dir,
        user_dir: system_dir,
        auth_methods: ~c"password",
        user_passwords: [{~c"alice", ~c"secret"}],
        app_opts: [test_pid: test_pid]
      )

    port = resolve_ssh_port(daemon)

    {:ok, conn} =
      :ssh.connect(~c"127.0.0.1", port,
        user: ~c"alice",
        password: ~c"secret",
        silently_accept_hosts: true,
        user_dir: system_dir,
        user_interaction: false,
        auth_methods: ~c"password"
      )

    {:ok, chan} = :ssh_connection.session_channel(conn, :infinity)

    :success =
      :ssh_connection.ptty_alloc(conn, chan,
        term: ~c"xterm",
        width: @width,
        height: @height
      )

    :ok = :ssh_connection.shell(conn, chan)

    assert_receive {:mounted, server}, 2000
    assert_receive {:rendered, ^server, widgets}, 2000

    :ok = :ssh.close(conn)
    GenServer.stop(daemon)

    drain()
    widgets
  end

  defp render_ssh_after_event(system_dir, event) do
    test_pid = self()

    {:ok, daemon} =
      Daemon.start_link(
        mod: @app,
        name: nil,
        port: 0,
        system_dir: system_dir,
        user_dir: system_dir,
        auth_methods: ~c"password",
        user_passwords: [{~c"alice", ~c"secret"}],
        app_opts: [test_pid: test_pid]
      )

    port = resolve_ssh_port(daemon)

    {:ok, conn} =
      :ssh.connect(~c"127.0.0.1", port,
        user: ~c"alice",
        password: ~c"secret",
        silently_accept_hosts: true,
        user_dir: system_dir,
        user_interaction: false,
        auth_methods: ~c"password"
      )

    {:ok, chan} = :ssh_connection.session_channel(conn, :infinity)

    :success =
      :ssh_connection.ptty_alloc(conn, chan,
        term: ~c"xterm",
        width: @width,
        height: @height
      )

    :ok = :ssh_connection.shell(conn, chan)

    assert_receive {:mounted, server}, 2000
    assert_receive {:rendered, ^server, _initial}, 2000

    send(server, {:ex_ratatui_event, event})
    assert_receive {:rendered, ^server, widgets}, 2000

    :ok = :ssh.close(conn)
    GenServer.stop(daemon)

    drain()
    widgets
  end

  defp render_once_distributed(peer_node) do
    {:ok, listener} =
      :rpc.call(
        peer_node,
        ExRatatui.Test.PeerHelper,
        :start_listener_unlinked,
        [[mod: @app, name: nil, app_opts: [test_pid: self()]]]
      )

    {:ok, server} =
      :rpc.call(peer_node, Listener, :start_session, [self(), @width, @height, listener])

    assert_receive {:mounted, ^server}, 2000
    assert_receive {:rendered, ^server, widgets}, 2000

    GenServer.stop(server)
    :rpc.call(peer_node, Supervisor, :stop, [listener])

    drain()
    widgets
  end

  defp render_distributed_after_event(peer_node, event) do
    {:ok, listener} =
      :rpc.call(
        peer_node,
        ExRatatui.Test.PeerHelper,
        :start_listener_unlinked,
        [[mod: @app, name: nil, app_opts: [test_pid: self()]]]
      )

    {:ok, server} =
      :rpc.call(peer_node, Listener, :start_session, [self(), @width, @height, listener])

    assert_receive {:mounted, ^server}, 2000
    assert_receive {:rendered, ^server, _initial}, 2000

    send(server, {:ex_ratatui_event, event})
    assert_receive {:rendered, ^server, widgets}, 2000

    GenServer.stop(server)
    :rpc.call(peer_node, Supervisor, :stop, [listener])

    drain()
    widgets
  end

  ## Helpers --------------------------------------------------------------

  # Absorb any stray :rendered / :terminated / SSH data messages left
  # from the previous transport so the next assert_receive starts clean.
  defp drain do
    receive do
      {:rendered, _, _} -> drain()
      {:terminated, _, _} -> drain()
      {:mounted, _} -> drain()
      {:ssh_cm, _, _} -> drain()
    after
      0 -> :ok
    end
  end

  defp resolve_ssh_port(daemon_pid) do
    {:ok, daemon_ref} = Daemon.daemon_ref(daemon_pid)
    {:ok, info} = :ssh.daemon_info(daemon_ref)
    Keyword.fetch!(info, :port)
  end

  defp generate_host_key!(system_dir) do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    pem = :public_key.pem_encode([pem_entry])
    File.write!(Path.join(system_dir, "ssh_host_rsa_key"), pem)
  end
end
