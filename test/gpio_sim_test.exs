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

  setup do
    # Verify the test is being run with a clean environment
    assert GPIO.backend_info().pins_open == 0, "Some other test didn't stop cleanly"

    # Verify that the test leaves the environment clean
    on_exit(fn ->
      assert GPIO.backend_info().pins_open == 0, "Test didn't close all opened GPIOs"
    end)

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

  test "backend_info/0" do
    info = GPIO.backend_info()

    assert info.name == Circuits.GPIO.CDev
    assert info.pins_open == 0
  end

  test "enumerate/0" do
    all_gpios = GPIO.enumerate()
    assert is_list(all_gpios)

    # Filter out the gpio-sim lines
    sim_gpios =
      Enum.filter(all_gpios, fn info -> String.starts_with?(info.label, "gpio_sim_line_") end)

    assert length(sim_gpios) == length(@all_gpios)

    # Check that they all have the same controller
    %{controller: controller} = hd(sim_gpios)
    Enum.each(sim_gpios, fn info -> assert info.controller == controller end)

    # Check that they all have the expected location
    %{location: {gpiochip, _line}} = hd(sim_gpios)

    Enum.each(sim_gpios, fn info ->
      index = info.label |> String.replace("gpio_sim_line_", "") |> String.to_integer()
      assert info.location == {gpiochip, index}
    end)
  end

  describe "identifiers/1" do
    test "all known gpios" do
      {:ok, %{location: {gpiochip, 0}, controller: controller, label: @gpio0}} =
        GPIO.identifiers(@gpio0)

      Enum.each(@all_gpios, fn gpio_name ->
        assert {:ok, %{location: {^gpiochip, line}, controller: ^controller, label: label}} =
                 GPIO.identifiers(gpio_name)

        expected_label = "gpio_sim_line_#{line}"
        assert label == expected_label
      end)
    end

    test "variations" do
      {:ok, expected} = GPIO.identifiers(@gpio0)
      %{location: {gpiochip, 0}, controller: controller, label: @gpio0} = expected

      # Try out the two ways of indexing
      assert {:ok, ^expected} = GPIO.identifiers({controller, 0})
      assert {:ok, ^expected} = GPIO.identifiers({gpiochip, 0})

      # Try out the unrecommended lone integer index
      all_gpios = GPIO.enumerate()
      index = Enum.find_index(all_gpios, fn info -> info.label == @gpio0 end)

      assert {:ok, ^expected} = GPIO.identifiers(index)
    end

    test "unknown gpio" do
      assert {:error, :not_found} = GPIO.identifiers("non_existent_gpio")
    end
  end

  describe "status/1" do
    test "unopened gpio" do
      {:ok, status} = GPIO.status(@gpio0)
      assert status.direction in [:input, :output]
      assert status.pull_mode in [:pull_up, :pull_down, :none]
      assert status.consumer == ""
    end

    test "output gpio" do
      {:ok, gpio} = GPIO.open(@gpio0, :output)
      {:ok, status} = GPIO.status(@gpio0)
      assert status.direction == :output
      assert status.pull_mode == :none
      assert status.consumer == "circuits_gpio"
      GPIO.close(gpio)
    end

    test "input gpio" do
      {:ok, gpio} = GPIO.open(@gpio0, :input)
      {:ok, status} = GPIO.status(@gpio0)
      assert status.direction == :input
      assert status.pull_mode == :none
      assert status.consumer == "circuits_gpio"
      GPIO.close(gpio)
    end

    test "input pullup gpio" do
      {:ok, gpio} = GPIO.open(@gpio0, :input)
      :ok = GPIO.set_pull_mode(gpio, :pullup)
      {:ok, status} = GPIO.status(@gpio0)
      assert status.direction == :input
      assert status.pull_mode == :pullup
      assert status.consumer == "circuits_gpio"
      GPIO.close(gpio)
    end

    test "input pulldown gpio" do
      {:ok, gpio} = GPIO.open(@gpio0, :input)
      :ok = GPIO.set_pull_mode(gpio, :pulldown)
      {:ok, status} = GPIO.status(@gpio0)
      assert status.direction == :input
      assert status.pull_mode == :pulldown
      assert status.consumer == "circuits_gpio"
      GPIO.close(gpio)
    end

    test "unknown gpio" do
      assert {:error, :not_found} = GPIO.status("non_existent_gpio")
    end
  end

  describe "open/3" do
    test "opening as an output with no initial_value defaults to 0" do
      {:ok, gpio0} = GPIO.open(@gpio0, :output)
      assert gpio_sim_read(@gpio0) == 0
      GPIO.close(gpio0)
    end

    test "can set the output on open" do
      {:ok, gpio0} = GPIO.open(@gpio0, :output, initial_value: 1)
      assert gpio_sim_read(@gpio0) == 1
      GPIO.close(gpio0)

      {:ok, gpio0} = GPIO.open(@gpio0, :output, initial_value: 0)
      assert gpio_sim_read(@gpio0) == 0
      GPIO.close(gpio0)
    end

    test "can set pull mode in open" do
      {:ok, gpio} = GPIO.open(@gpio1, :input, pull_mode: :pullup)
      GPIO.close(gpio)
    end

    test "raises argument error on invalid gpio_spec" do
      assert_raise ArgumentError, fn -> GPIO.open(:invalid_gpio_spec, :output) end
    end

    test "raises argument error on invalid direction" do
      assert_raise ArgumentError, fn -> GPIO.open(@gpio0, :bogus) end
    end

    test "ignores unknown open options" do
      {:ok, gpio} = GPIO.open(@gpio1, :input, bogus: true)
      GPIO.close(gpio)
    end

    test "open returns an error on invalid index" do
      {:ok, %{location: {gpiochip, 0}}} = GPIO.identifiers(@gpio0)
      assert GPIO.open({gpiochip, 100}, :input) == {:error, :not_found}
    end

    test "open returns an error on invalid label" do
      assert GPIO.open("gpio_sim_line_100", :input) == {:error, :not_found}
    end

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

    test "lots of gpio refs can be created" do
      assert GPIO.backend_info().pins_open == 0

      # Expect that the process dying will free up all of the pins
      me = self()

      {pid, ref} =
        spawn_monitor(fn ->
          x = Enum.map(@all_gpios, fn label -> {:ok, _ref} = GPIO.open(label, :input) end)
          count = length(x)
          assert GPIO.backend_info().pins_open == count
          send(me, :done)
        end)

      # Wait to allow spawned task to complete
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

      refute Process.alive?(pid)
      assert_receive :done

      :erlang.garbage_collect()

      # Wait a fraction of a second to allow GC to run since there's
      # a race between the send and the GC actually running.
      Process.sleep(100)

      assert GPIO.backend_info().pins_open == 0
    end
  end

  describe "set_direction/2" do
    test "can set direction" do
      gpio_sim_write(@gpio0, 0)
      {:ok, gpio} = GPIO.open(@gpio0, :output)
      GPIO.write(gpio, 1)
      assert gpio_sim_read(@gpio0) == 1
      assert GPIO.set_direction(gpio, :input) == :ok
      assert gpio_sim_read(@gpio0) == 1
      assert GPIO.set_direction(gpio, :output) == :ok
      assert gpio_sim_read(@gpio0) == 0
      GPIO.close(gpio)
    end
  end

  describe "set_pull_mode/2" do
    test "can set pull mode" do
      gpio_sim_write(@gpio0, 0)
      {:ok, gpio} = GPIO.open(@gpio0, :input)
      assert gpio_sim_read(@gpio0) == 0
      assert GPIO.set_pull_mode(gpio, :not_set) == :ok
      assert gpio_sim_read(@gpio0) == 0
      assert GPIO.set_pull_mode(gpio, :none) == :ok
      assert gpio_sim_read(@gpio0) == 0
      assert GPIO.set_pull_mode(gpio, :pullup) == :ok
      assert gpio_sim_read(@gpio0) == 1
      assert GPIO.set_pull_mode(gpio, :pulldown) == :ok
      assert gpio_sim_read(@gpio0) == 0
      GPIO.close(gpio)
    end
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

  test "unloading NIF" do
    # The theory here is that there shouldn't be a crash if this is reloaded a
    # few times.
    for _times <- 1..10 do
      assert {:module, Circuits.GPIO} == :code.ensure_loaded(Circuits.GPIO)
      assert {:module, Circuits.GPIO.Nif} == :code.ensure_loaded(Circuits.GPIO.Nif)

      # Try running something to verify that it works.
      {:ok, gpio} = GPIO.open(@gpio1, :input)
      assert is_struct(gpio, Circuits.GPIO.CDev)
      GPIO.close(gpio)

      assert true == :code.delete(Circuits.GPIO.Nif)
      assert true == :code.delete(Circuits.GPIO)

      # The purge will call the unload which can be verified by turning DEBUG on
      # in the C code.
      assert false == :code.purge(Circuits.GPIO.Nif)
      assert false == :code.purge(Circuits.GPIO)
    end
  end
end
