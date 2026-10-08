# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.Error do
  @moduledoc """
  `DNSServiceErrorType` codes from `dns_sd.h`, as atoms.

  A code with no name here is reported as `{:dns_service_error, code}`.
  """

  @codes %{
    -65_537 => :unknown,
    -65_538 => :no_such_name,
    -65_539 => :no_memory,
    -65_540 => :bad_param,
    -65_541 => :bad_reference,
    -65_542 => :bad_state,
    -65_543 => :bad_flags,
    -65_544 => :unsupported,
    -65_545 => :not_initialized,
    -65_547 => :already_registered,
    -65_548 => :name_conflict,
    -65_549 => :invalid,
    -65_550 => :firewall,
    -65_551 => :incompatible,
    -65_552 => :bad_interface_index,
    -65_553 => :refused,
    -65_554 => :no_such_record,
    -65_555 => :no_auth,
    -65_556 => :no_such_key,
    -65_557 => :nat_traversal,
    -65_558 => :double_nat,
    -65_559 => :bad_time,
    -65_560 => :bad_sig,
    -65_561 => :bad_key,
    -65_562 => :transient,
    -65_563 => :service_not_running,
    -65_564 => :nat_port_mapping_unsupported,
    -65_565 => :nat_port_mapping_disabled,
    -65_566 => :no_router,
    -65_567 => :polling_mode,
    -65_568 => :timeout,
    -65_569 => :defunct_connection,
    -65_570 => :policy_denied,
    -65_571 => :not_permitted
  }

  @type reason :: atom() | {:dns_service_error, integer()}

  @doc "The reason for a `DNSServiceErrorType` code."
  @spec reason(integer()) :: reason()
  def reason(code), do: Map.get(@codes, code, {:dns_service_error, code})
end
