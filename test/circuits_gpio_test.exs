# SPDX-FileCopyrightText: 2018 Frank Hunleth
# SPDX-FileCopyrightText: 2019 Mark Sebald
# SPDX-FileCopyrightText: 2019 Matt Ludwigs
# SPDX-FileCopyrightText: 2023 Connor Rigby
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIOTest do
  use ExUnit.Case
  require Circuits.GPIO
  alias Circuits.GPIO

  test "is_gpio_spec/1" do
    assert GPIO.is_gpio_spec("PA8")
    assert GPIO.is_gpio_spec(1 * 1 * 32 + 8)
    assert GPIO.is_gpio_spec({"gpiochip0", 8})
    assert GPIO.is_gpio_spec({"gpiochip0", "PA8"})
    refute GPIO.is_gpio_spec({nil, nil})
    refute GPIO.is_gpio_spec(nil)
    refute GPIO.is_gpio_spec(%{})
  end

  test "gpio_spec?/1" do
    assert GPIO.gpio_spec?("PA8")
    assert GPIO.gpio_spec?(1 * 1 * 32 + 8)
    assert GPIO.gpio_spec?({"gpiochip0", 8})
    assert GPIO.gpio_spec?({"gpiochip0", "PA8"})
    refute GPIO.gpio_spec?({nil, nil})
    refute GPIO.gpio_spec?(nil)
    refute GPIO.gpio_spec?(%{})
  end
end
