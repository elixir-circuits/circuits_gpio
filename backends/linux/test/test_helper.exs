# SPDX-FileCopyrightText: 2022 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

if not GPIOSim.detected?() do
  IO.puts("WARNING: Skipping tests that require gpio-sim. See README_GPIO_SIM.md.")
  ExUnit.configure(exclude: :gpio_sim)
end

ExUnit.start()
