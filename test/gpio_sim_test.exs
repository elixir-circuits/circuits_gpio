# SPDX-FileCopyrightText: 2025 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

# This test module validates the circuits_gpio cdev backend with gpio-sim,
# a Linux kernel module that simulates GPIO hardware. Unlike the regular
# test suite which uses a stub backend, this test uses the real cdev backend
# with actual kernel GPIO subsystem integration.
#
# Prerequisites:
# - Linux kernel with gpio-sim support (5.17+)
# - Run ./setup_gpio_sim.sh first to configure gpio-sim
# - libgpiod tools installed
#
# Run with: mix test --include gpio_sim

defmodule Circuits.GPIOSimTest do
  use ExUnit.Case
  require Circuits.GPIO
  alias Circuits.GPIO

  @moduletag :gpio_sim

  # GPIO simulator device - this will be a symlink created by the setup script
  @gpio_sim_chip "gpiochip_sim"

  # GPIO line numbers used for testing
  @output_pin 0
  @input_pin 1

  setup_all do
    # Check if gpio-sim device is available
    case File.exists?("/dev/gpiochip_sim") do
      true ->
        # Force the use of real cdev backend (not test mode) for this test
        old_backend = Application.get_env(:circuits_gpio, :default_backend)
        Application.put_env(:circuits_gpio, :default_backend, Circuits.GPIO.CDev)

        on_exit(fn ->
          # Restore original backend
          if old_backend do
            Application.put_env(:circuits_gpio, :default_backend, old_backend)
          else
            Application.delete_env(:circuits_gpio, :default_backend)
          end
        end)

        :ok
      false ->
        IO.puts("GPIO simulator not found. Run ./setup_gpio_sim.sh first")
        ExUnit.configure(exclude: :gpio_sim)
        :ok
    end
  end

  setup do
    # For gpio-sim tests, we may have pins open from other processes
    # so we'll just verify our test cleans up after itself
    pins_open_before = GPIO.backend_info().pins_open

    # Verify that this test cleans up its own pins
    on_exit(fn ->
      pins_open_after = GPIO.backend_info().pins_open
      if pins_open_after > pins_open_before do
        raise "Test didn't close all opened GPIOs: #{pins_open_after - pins_open_before} pins still open"
      end
    end)

    :ok
  end

  @tag timeout: 10_000
  test "gpio-sim interrupt setup and basic functionality" do
    # This test verifies that:
    # 1. We can open GPIO pins on gpio-sim devices
    # 2. We can set up interrupts without errors
    # 3. The cdev backend works with real hardware (gpio-sim)

    # Open input pin for detecting interrupts
    {:ok, input_gpio} = GPIO.open({@gpio_sim_chip, @input_pin}, :input)

    # Verify we can read the initial state
    initial_value = GPIO.read(input_gpio)
    assert initial_value in [0, 1], "GPIO read should return 0 or 1"

    # Set up interrupt detection on both edges - this should not crash
    :ok = GPIO.set_interrupts(input_gpio, :both)

    # Ensure no spurious interrupts
    refute_receive {:circuits_gpio, {@gpio_sim_chip, @input_pin}, _timestamp, _}, 100

    # Test changing interrupt modes
    :ok = GPIO.set_interrupts(input_gpio, :rising)
    :ok = GPIO.set_interrupts(input_gpio, :falling)
    :ok = GPIO.set_interrupts(input_gpio, :none)

    # Verify we can open an output pin as well
    {:ok, output_gpio} = GPIO.open({@gpio_sim_chip, @output_pin}, :output)

    # Test basic write operations
    :ok = GPIO.write(output_gpio, 0)
    :ok = GPIO.write(output_gpio, 1)
    :ok = GPIO.write(output_gpio, 0)

    # Clean up
    GPIO.close(output_gpio)
    GPIO.close(input_gpio)

    # This test validates that the cdev backend works with real GPIO hardware
    # For actual interrupt testing with stimulus, external tools or hardware
    # connections would be needed
  end
end
