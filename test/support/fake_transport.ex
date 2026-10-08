# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.FakeTransport do
  @moduledoc false
  # Plays `bonjex_port` for unit tests. Pass `transport: Bonjex.FakeTransport`
  # and `test: self()` to `Bonjex.start_link/1`. Each port opened is announced
  # to the test as `{:fake_port, handle, conn}`, and each command arrives as
  # `{:frame, fields}`. `reply/3` and `exit/2` play the port's side.

  @behaviour Bonjex.Transport

  @impl true
  def open(opts) do
    test = Keyword.fetch!(opts, :test)
    handle = make_ref()
    :persistent_term.put({__MODULE__, handle}, test)
    send(test, {:fake_port, handle, self()})
    {:ok, handle}
  end

  @impl true
  def command(handle, data) do
    test = :persistent_term.get({__MODULE__, handle})
    fields = data |> IO.iodata_to_binary() |> :binary.split("\t", [:global])
    send(test, {:frame, Enum.map(fields, &Bonjex.Protocol.unescape/1)})
    :ok
  end

  @impl true
  def close(_handle), do: :ok

  @doc "Delivers a reply frame to the connection, as the port would."
  def reply(conn, handle, fields) do
    send(conn, {handle, {:data, IO.iodata_to_binary(Bonjex.Protocol.encode(fields))}})
    :ok
  end

  @doc "Makes the port exit."
  def exit(conn, handle, status \\ 1) do
    send(conn, {handle, {:exit_status, status}})
    :ok
  end
end
