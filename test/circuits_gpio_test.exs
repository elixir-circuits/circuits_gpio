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

  test "refresh enumeration cache" do
    bogus_gpio = %{
      location: {"gpiochip10", 5},
      label: "not_a_gpio",
      controller: "not_a_controller"
    }
    bogus_gpio_list = [bogus_gpio]

    # Set the cache to something bogus and check that it's comes back
    :persistent_term.put(Circuits.GPIO.CDev, bogus_gpio_list)

    assert GPIO.identifiers("not_a_gpio") == {:ok, bogus_gpio}
    assert GPIO.enumerate() == bogus_gpio_list

    # Now check that the cache gets refreshed when a gpio isn't found
    _ = GPIO.identifiers("anything_else")
    assert GPIO.enumerate() != bogus_gpio_list

    # The bogus GPIO doesn't come back
    assert GPIO.identifiers("not_a_gpio") == {:error, :not_found}
  end
end
