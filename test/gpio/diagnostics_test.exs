# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.DiagnosticsTest do
  use ExUnit.Case
  alias Circuits.GPIO.Diagnostics

  import ExUnit.CaptureIO

  @gpio0 "gpio_sim_line_0"
  @gpio1 "gpio_sim_line_1"

  test "report/2" do
    _ = start_supervised!({GPIOSimWire, read: @gpio0, write: @gpio1})

    output = capture_io(fn -> Diagnostics.report(@gpio0, @gpio1, skip_pullup_tests?: true) end)
    assert output =~ "All tests passed"
  end

  test "run/2" do
    _ = start_supervised!({GPIOSimWire, read: @gpio0, write: @gpio1})
    results = Diagnostics.run(@gpio0, @gpio1, skip_pullup_tests?: true)

    assert Enum.all?(results, fn {_name, result} -> result == :ok end)
  end

  test "speed_test/1" do
    results = Diagnostics.speed_test(@gpio0)

    # Just check that the result is not completely bogus
    assert results.write_cps > 1000
    assert results.read_cps > 1000
    assert results.write_one_cps > ceil(results.write_cps / 10000)
    assert results.read_one_cps > ceil(results.read_cps / 10000)
  end
end
