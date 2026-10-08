# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

# The `:live` tests drive the real port program against the host's DNS-SD
# responder, with real multicast settling time. They run only where the port
# program was built and are excluded by default:
#
#     mix test --include live
Logger.configure(level: :info)
ExUnit.start(exclude: [:live])
