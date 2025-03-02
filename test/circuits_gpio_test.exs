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

  doctest GPIO

  setup do
    # Verify the test is being run with a clean environment
    assert GPIO.backend_info().pins_open == 0, "Some other test didn't stop cleanly"

    # Verify that the test leaves the environment clean
    on_exit(fn ->
      assert GPIO.backend_info().pins_open == 0, "Test didn't close all opened GPIOs"
    end)

    :ok
  end

  # not a real gpiochip, just used for testing
  @gpiochip "gpiochip0"

  # Many of these tests take advantage of the "stub" HAL. The "stub"
  # HAL connects GPIO 0 to 1, 2 to 3, etc. It is useful for testing
  # the interface and much of the NIF source code without needing
  # real hardware.

  test "info returns a map" do
    info = GPIO.backend_info()

    assert is_map(info)
    assert info.name == {Circuits.GPIO.CDev, [test: true]}
    assert info.pins_open == 0
  end

  describe "identifiers/2" do
    test "all gpio_spec examples" do
      expected = %{
        location: {"gpiochip0", 5},
        label: "pair_2_1",
        controller: "stub0"
      }

      assert GPIO.identifiers(5) == {:ok, expected}
      assert GPIO.identifiers("pair_2_1") == {:ok, expected}
      assert GPIO.identifiers({"gpiochip0", 5}) == {:ok, expected}
      assert GPIO.identifiers({"stub0", 5}) == {:ok, expected}
      assert GPIO.identifiers({"gpiochip0", "pair_2_1"}) == {:ok, expected}
      assert GPIO.identifiers({"stub0", "pair_2_1"}) == {:ok, expected}

      assert GPIO.identifiers(-1) == {:error, :not_found}
      assert GPIO.identifiers(64) == {:error, :not_found}
      assert GPIO.identifiers("something") == {:error, :not_found}
      assert GPIO.identifiers({"gpiochip0", 64}) == {:error, :not_found}
      assert GPIO.identifiers({"stub0", 64}) == {:error, :not_found}
      assert GPIO.identifiers({"gpiochip0", "something"}) == {:error, :not_found}
      assert GPIO.identifiers({"stub0", "something"}) == {:error, :not_found}
    end

    test "lines in stub1" do
      for spec <- [33, "pair_16_1", {"stub1", "pair_16_1"}] do
        info = GPIO.identifiers(spec)

        expected_line_info = %{
          location: {"gpiochip1", 1},
          label: "pair_16_1",
          controller: "stub1"
        }

        assert info == {:ok, expected_line_info},
               "Unexpected info for #{inspect(spec)} -> #{inspect(info)}"
      end
    end

    test "nonexistent lines" do
      for spec <- [-1, 65, "pair_100_0", {"stub10", "pair_2_0"}] do
        info = GPIO.identifiers(spec)

        assert info == {:error, :not_found},
               "Unexpected info for #{inspect(spec)} -> #{inspect(info)}"
      end
    end
  end

  describe "status/2" do
    test "all gpio_spec examples" do
      expected = %{consumer: "", direction: :input, pull_mode: :none}

      assert GPIO.status(5) == {:ok, expected}
      assert GPIO.status("pair_2_1") == {:ok, expected}
      assert GPIO.status({"gpiochip0", 5}) == {:ok, expected}
      assert GPIO.status({"stub0", 5}) == {:ok, expected}
      assert GPIO.status({"gpiochip0", "pair_2_1"}) == {:ok, expected}
      assert GPIO.status({"stub0", "pair_2_1"}) == {:ok, expected}

      assert GPIO.status(-1) == {:error, :not_found}
      assert GPIO.status(64) == {:error, :not_found}
      assert GPIO.status("something") == {:error, :not_found}
      assert GPIO.status({"gpiochip0", 64}) == {:error, :not_found}
      assert GPIO.status({"stub0", 64}) == {:error, :not_found}
      assert GPIO.status({"gpiochip0", "something"}) == {:error, :not_found}
      assert GPIO.status({"stub0", "something"}) == {:error, :not_found}
    end

    test "status reports output gpio" do
      {:ok, gpio} = GPIO.open({@gpiochip, 1}, :output)

      assert GPIO.status({@gpiochip, 1}) ==
               {:ok,
                %{
                  consumer: "stub",
                  direction: :output,
                  pull_mode: :none
                }}

      GPIO.close(gpio)
    end

    test "status reports input gpio" do
      {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input, pull_mode: :pullup)

      assert GPIO.status({@gpiochip, 1}) ==
               {:ok,
                %{
                  consumer: "stub",
                  direction: :input,
                  pull_mode: :pullup
                }}

      GPIO.close(gpio)
    end
  end

  test "opening and closing a pin gets counted" do
    {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input)
    assert is_struct(gpio, Circuits.GPIO.CDev)

    assert GPIO.backend_info().pins_open == 1

    GPIO.close(gpio)
    assert GPIO.backend_info().pins_open == 0
  end

  test "open returns errors on invalid pins" do
    # The stub returns error on any pin numbers >= 64
    assert GPIO.open({@gpiochip, 100}, :input) == {:error, :not_found}
  end

  test "gpio refs get garbage collected" do
    assert GPIO.backend_info().pins_open == 0

    # Expect that the process dying will free up the pin
    me = self()

    spawn_link(fn ->
      {:ok, _ref} = GPIO.open({@gpiochip, 1}, :input)
      send(me, :done)
    end)

    assert_receive :done

    # Wait a fraction of a second to allow GC to run since there's
    # a race between the send and the GC actually running.
    Process.sleep(10)

    assert GPIO.backend_info().pins_open == 0
  end

  test "lots of gpio refs can be created" do
    assert GPIO.backend_info().pins_open == 0

    # Expect that the process dying will free up all of the pins
    me = self()
    count = 10_000

    {pid, ref} =
      spawn_monitor(fn ->
        x = Enum.map(1..count, fn _ -> {:ok, _ref} = GPIO.open({@gpiochip, 1}, :input) end)
        ^count = GPIO.backend_info().pins_open
        send(me, {:done, length(x)})
      end)

    # Wait to allow spawned task to complete
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

    refute Process.alive?(pid)
    assert_receive {:done, ^count}

    :erlang.garbage_collect()

    # Wait a fraction of a second to allow GC to run since there's
    # a race between the send and the GC actually running.
    Process.sleep(100)

    assert GPIO.backend_info().pins_open == 0
  end

  test "can read and write gpio" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

    :ok = GPIO.write(gpio0, 1)
    assert GPIO.read(gpio1) == 1
    :ok = GPIO.write(gpio0, 0)
    assert GPIO.read(gpio1) == 0

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "can set direction" do
    {:ok, gpio} = GPIO.open({@gpiochip, 0}, :output)
    assert GPIO.set_direction(gpio, :input) == :ok
    assert GPIO.set_direction(gpio, :output) == :ok
    GPIO.close(gpio)
  end

  test "can set pull mode" do
    {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input)
    assert GPIO.set_pull_mode(gpio, :not_set) == :ok
    assert GPIO.set_pull_mode(gpio, :none) == :ok
    assert GPIO.set_pull_mode(gpio, :pullup) == :ok
    assert GPIO.set_pull_mode(gpio, :pulldown) == :ok
    GPIO.close(gpio)
  end

  test "can set pull mode in open" do
    {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input, pull_mode: :pullup)
    GPIO.close(gpio)
  end

  test "raises argument error on invalid gpio_spec" do
    assert_raise ArgumentError, fn -> GPIO.open(:invalid_gpio_spec, :output) end
  end

  test "raises argument error on invalid direction" do
    assert_raise ArgumentError, fn -> GPIO.open({@gpiochip, 0}, :bogus) end
  end

  test "ignores unknown open options" do
    {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input, bogus: true)
    GPIO.close(gpio)
  end

  test "no initial interrupt on set_interrupts" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

    :ok = GPIO.set_interrupts(gpio1, :both)
    refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "interrupts on both edges" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

    :ok = GPIO.set_interrupts(gpio1, :both)
    refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

    :ok = GPIO.write(gpio0, 1)
    assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 1}

    :ok = GPIO.write(gpio0, 0)
    assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "interrupt with various specs" do
    # Test that interrupts sent the original spec that they were opened with
    for spec1 <- [33, "pair_16_1", {"stub1", "pair_16_1"}] do
      {:ok, gpio0} = GPIO.open({"gpiochip1", 0}, :output)
      {:ok, gpio1} = GPIO.open(spec1, :input)

      :ok = GPIO.set_interrupts(gpio1, :both)
      refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

      :ok = GPIO.write(gpio0, 1)
      assert_receive {:circuits_gpio, ^spec1, _timestamp, 1}

      :ok = GPIO.write(gpio0, 0)
      assert_receive {:circuits_gpio, ^spec1, _timestamp, 0}

      GPIO.close(gpio0)
      GPIO.close(gpio1)
    end
  end

  test "interrupts on falling edges" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

    :ok = GPIO.set_interrupts(gpio1, :falling)
    refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

    :ok = GPIO.write(gpio0, 1)
    refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 1}

    :ok = GPIO.write(gpio0, 0)
    assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "interrupts on rising edges" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

    :ok = GPIO.set_interrupts(gpio1, :rising)
    refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

    :ok = GPIO.write(gpio0, 1)
    assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 1}

    :ok = GPIO.write(gpio0, 0)
    refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "can disable interrupts" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

    :ok = GPIO.set_interrupts(gpio1, :both)
    refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

    :ok = GPIO.write(gpio0, 1)
    assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 1}

    :ok = GPIO.set_interrupts(gpio1, :none)
    :ok = GPIO.write(gpio0, 0)
    refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "no interrupts after closing" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 1}, :input)

    :ok = GPIO.set_interrupts(gpio1, :both)
    refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, _}

    :ok = GPIO.write(gpio0, 1)
    assert_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 1}

    GPIO.close(gpio1)
    Process.sleep(10)

    :ok = GPIO.write(gpio0, 0)
    refute_receive {:circuits_gpio, {@gpiochip, 1}, _timestamp, 0}

    GPIO.close(gpio0)
  end

  test "opening as an output with no initial_value defaults to 0" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO.open({@gpiochip, 0}, :input)
    :ok = GPIO.write(gpio0, 1)
    assert GPIO.read(gpio1) == 1
    GPIO.close(gpio0)

    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output)
    assert GPIO.read(gpio1) == 0
    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "can set the output on open" do
    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output, initial_value: 1)
    assert GPIO.read(gpio0) == 1
    GPIO.close(gpio0)

    {:ok, gpio0} = GPIO.open({@gpiochip, 0}, :output, initial_value: 0)
    assert GPIO.read(gpio0) == 0
    GPIO.close(gpio0)
  end

  test "can enumerate GPIOs" do
    result = GPIO.enumerate()
    assert length(result) == 64

    assert hd(result) == %{
             location: {"gpiochip0", 0},
             controller: "stub0",
             label: "pair_0_0"
           }

    assert List.last(result) == %{
             location: {"gpiochip1", 31},
             controller: "stub1",
             label: "pair_31_1"
           }
  end

  test "can open all enumerated GPIOs" do
    result = GPIO.enumerate()

    Enum.each(result, fn info ->
      # This also tests opening by info
      {:ok, ref} = GPIO.open(info, :input)
      GPIO.close(ref)
    end)
  end

  test "unloading NIF" do
    # The theory here is that there shouldn't be a crash if this is reloaded a
    # few times.
    for _times <- 1..10 do
      assert {:module, Circuits.GPIO} == :code.ensure_loaded(Circuits.GPIO)
      assert {:module, Circuits.GPIO.Nif} == :code.ensure_loaded(Circuits.GPIO.Nif)

      # Try running something to verify that it works.
      {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input)
      assert is_struct(gpio, Circuits.GPIO.CDev)

      assert GPIO.backend_info().pins_open == 1

      GPIO.close(gpio)
      assert GPIO.backend_info().pins_open == 0

      assert true == :code.delete(Circuits.GPIO.Nif)
      assert true == :code.delete(Circuits.GPIO)

      # The purge will call the unload which can be verified by turning DEBUG on
      # in the C code.
      assert false == :code.purge(Circuits.GPIO.Nif)
      assert false == :code.purge(Circuits.GPIO)
    end
  end

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

    good_gpio = %{
      location: {"gpiochip1", 5},
      label: "pair_18_1",
      controller: "stub1"
    }

    # Set the cache to something bogus and check that it's comes back
    :persistent_term.put(Circuits.GPIO.CDev, [bogus_gpio])
    assert GPIO.identifiers("not_a_gpio") == {:ok, bogus_gpio}

    # Now check that the cache gets refreshed when a gpio isn't found
    assert GPIO.identifiers("pair_18_1") == {:ok, good_gpio}

    # The bogus GPIO doesn't come back
    assert GPIO.identifiers("not_a_gpio") == {:error, :not_found}
  end

  test "write_one/2 + read_one/1" do
    assert GPIO.read_one({@gpiochip, 0}) == 0
    assert GPIO.write_one({@gpiochip, 1}, 1) == :ok
    assert GPIO.read_one({@gpiochip, 0}) == 1
  end
end
