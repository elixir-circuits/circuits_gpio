# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.DiagnosticsTest do
  use ExUnit.Case
  alias Circuits.GPIO.Diagnostics

  import ExUnit.CaptureIO

  test "report/2" do
    output = capture_io(fn -> Diagnostics.report(0, 1) end)
    assert output =~ "All tests passed"
  end

  test "run/2" do
    results = Diagnostics.run(2, 3)

    assert Enum.all?(results, fn {_name, result} -> result == :ok end)
  end

  test "speed_test/1" do
    results = Diagnostics.speed_test(10)

    # Just check that the result is not completely bogus
    assert results.writes_per_sec > 1000
    assert results.reads_per_sec > 1000
  end
end
