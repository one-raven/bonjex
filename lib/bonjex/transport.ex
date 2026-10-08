# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.Transport do
  @moduledoc """
  How a `Bonjex` connection reaches the port program.

  The default, `Bonjex.Transport.Port`, spawns `bonjex_port`. A test can pass
  its own module as the `:transport` option to `Bonjex.start_link/1` and play
  the port's side of the protocol.

  The process that called `c:open/1` must receive `{handle, {:data, binary}}`
  for each frame the port writes, and `{handle, {:exit_status, integer}}`
  when it exits, as an Erlang port opened with `{:packet, 4}` and
  `:exit_status` delivers them.
  """

  @type handle :: term()

  @doc "Starts the port program. The options are those given to the connection."
  @callback open(keyword()) :: {:ok, handle()} | {:error, term()}

  @doc "Sends one frame."
  @callback command(handle(), iodata()) :: :ok

  @doc "Stops the port program."
  @callback close(handle()) :: :ok
end
