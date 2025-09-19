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
  alias Circuits.GPIO

  @moduletag :gpio_sim

  @gpio0 "gpio_sim_line_0"
  @gpio1 "gpio_sim_line_1"
  @all_gpios [
    "gpio_sim_line_0",
    "gpio_sim_line_1",
    "gpio_sim_line_2",
    "gpio_sim_line_3",
    "gpio_sim_line_4",
    "gpio_sim_line_5",
    "gpio_sim_line_6",
    "gpio_sim_line_7"
  ]

  setup_all do
    if not File.exists?("/dev/gpiochip_sim") do
      IO.puts("GPIO simulator not found. Run ./setup_gpio_sim.sh first")
      ExUnit.configure(exclude: :gpio_sim)
    end

    :ok
  end

  defp line_path(gpio_name) do
    {:ok, %{location: {gpiochip, line}, controller: controller}} = GPIO.identifiers(gpio_name)
    base_controller = String.replace(controller, "-node0", "")
    "/sys/devices/platform/#{base_controller}/#{gpiochip}/sim_gpio#{line}"
  end

  defp gpio_sim_write(gpio_name, value) do
    pull_path = Path.join(line_path(gpio_name), "pull")
    pull_dir = if value > 0, do: "pull-up", else: "pull-down"
    File.write!(pull_path, pull_dir)
  end

  defp gpio_sim_read(gpio_name) do
    value_path = Path.join(line_path(gpio_name), "value")
    {value_str, 0} = System.cmd("cat", [value_path])
    String.trim(value_str) |> String.to_integer()
  end

  describe "basic operations" do
    test "read/1" do
      {:ok, gpio} = GPIO.open(@gpio0, :input)

      gpio_sim_write(@gpio0, 0)
      assert GPIO.read(gpio) == 0

      gpio_sim_write(@gpio0, 1)
      assert GPIO.read(gpio) == 1

      GPIO.close(gpio)
    end

    test "write/2" do
      {:ok, gpio} = GPIO.open(@gpio0, :output)

      :ok = GPIO.write(gpio, 0)
      assert gpio_sim_read(@gpio0) == 0

      :ok = GPIO.write(gpio, 1)
      assert gpio_sim_read(@gpio0) == 1

      GPIO.close(gpio)
    end

    test "read_one/2" do
      gpio_sim_write(@gpio0, 0)
      assert GPIO.read_one(@gpio0) == 0
      gpio_sim_write(@gpio0, 1)
      assert GPIO.read_one(@gpio0) == 1
    end

    test "write_one/2" do
      # NOTE: gpio-sim does not persist values after close so this test
      #       checks the expected behavior rather than what happens with
      #       a real GPIO line.

      # Ensure starting from a known starting state
      gpio_sim_write(@gpio0, 0)

      GPIO.write_one(@gpio0, 0)
      assert gpio_sim_read(@gpio0) == 0

      GPIO.write_one(@gpio0, 1)
      assert gpio_sim_read(@gpio0) == 0
    end
  end

  describe "interrupts" do
    test "basic both-sided interrupts" do
      gpio_sim_write(@gpio0, 0)
      {:ok, gpio} = GPIO.open(@gpio0, :input)

      assert GPIO.read(gpio) == 0

      :ok = GPIO.set_interrupts(gpio, :both)
      refute_receive _

      gpio_sim_write(@gpio0, 1)
      assert_receive {:circuits_gpio, @gpio0, _, 1}

      gpio_sim_write(@gpio0, 0)
      assert_receive {:circuits_gpio, @gpio0, _, 0}

      GPIO.close(gpio)
      refute_receive _
    end

    test "basic rising interrupts" do
      gpio_sim_write(@gpio0, 0)
      {:ok, gpio} = GPIO.open(@gpio0, :input)

      assert GPIO.read(gpio) == 0

      :ok = GPIO.set_interrupts(gpio, :rising)
      refute_receive _

      gpio_sim_write(@gpio0, 1)
      assert_receive {:circuits_gpio, @gpio0, _, 1}

      gpio_sim_write(@gpio0, 0)
      refute_receive _

      gpio_sim_write(@gpio0, 1)
      assert_receive {:circuits_gpio, @gpio0, _, 1}

      GPIO.close(gpio)
      refute_receive _
    end

    test "basic falling interrupts" do
      gpio_sim_write(@gpio0, 1)
      {:ok, gpio} = GPIO.open(@gpio0, :input)

      assert GPIO.read(gpio) == 1

      :ok = GPIO.set_interrupts(gpio, :falling)
      refute_receive _

      gpio_sim_write(@gpio0, 0)
      assert_receive {:circuits_gpio, @gpio0, _, 0}

      gpio_sim_write(@gpio0, 1)
      refute_receive _

      gpio_sim_write(@gpio0, 0)
      assert_receive {:circuits_gpio, @gpio0, _, 0}

      GPIO.close(gpio)
      refute_receive _
    end

    test "multiple GPIOs" do
      Enum.each(@all_gpios, fn gpio_name -> gpio_sim_write(gpio_name, 0) end)

      gpios =
        Enum.map(@all_gpios, fn gpio_name ->
          {:ok, gpio} = GPIO.open(gpio_name, :input)
          GPIO.set_interrupts(gpio, :both)
          gpio
        end)

      Enum.each(@all_gpios, fn gpio_name ->
        gpio_sim_write(gpio_name, 1)
        assert_receive {:circuits_gpio, ^gpio_name, _, 1}
        refute_received _
      end)

      Enum.each(@all_gpios, fn gpio_name ->
        gpio_sim_write(gpio_name, 0)
        assert_receive {:circuits_gpio, ^gpio_name, _, 0}
      end)

      Enum.each(gpios, fn gpio -> GPIO.close(gpio) end)
      refute_receive _
    end

    test "reopen affecting other GPIO interrupts" do
      # This exercises a former bug in interrupt accounting in the cdev backend.
      gpio_sim_write(@gpio0, 0)
      gpio_sim_write(@gpio1, 0)

      {:ok, gpio0} = GPIO.open(@gpio0, :input)
      GPIO.set_interrupts(gpio0, :both)
      {:ok, gpio1} = GPIO.open(@gpio1, :input)
      GPIO.set_interrupts(gpio1, :both)

      gpio_sim_write(@gpio0, 1)
      assert_receive {:circuits_gpio, @gpio0, _, 1}

      GPIO.close(gpio0)
      {:ok, gpio0} = GPIO.open(@gpio0, :input)
      GPIO.set_interrupts(gpio0, :both)
      gpio_sim_write(@gpio0, 0)
      assert_receive {:circuits_gpio, @gpio0, _, 0}

      # Bug was that gpio 1 interrupts were lost after reopening gpio0
      gpio_sim_write(@gpio1, 1)
      assert_receive {:circuits_gpio, @gpio1, _, 1}

      GPIO.close(gpio0)
      GPIO.close(gpio1)
      refute_receive _
    end
  end

  describe "open/3" do
    test "gpio refs get garbage collected" do
      # Expect that the process dying will free up the pin
      me = self()

      spawn_link(fn ->
        {:ok, _ref} = GPIO.open(@gpio1, :input)
        send(me, :done)
      end)

      assert_receive :done

      # Wait a fraction of a second to allow GC to run since there's
      # a race between the send and the GC actually running.
      Process.sleep(10)

      # Check that it's possible to re-open
      {:ok, ref} = GPIO.open(@gpio1, :input)
      GPIO.close(ref)
    end
  end
end
