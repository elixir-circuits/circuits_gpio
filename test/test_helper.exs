# SPDX-FileCopyrightText: 2014 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

# Enable ExUnit to use colors, but not the code under test. This is for
# testing Circuits.GPIO.Diagnostics.report/2.
colors_enabled? = IO.ANSI.enabled?()
Application.put_env(:elixir, :ansi_enabled, false)
ExUnit.start(colors: [enabled: colors_enabled?])
