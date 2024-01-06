# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO2Test do
  use ExUnit.Case
  require Circuits.GPIO
  alias Circuits.GPIO
  alias Circuits.GPIO.Line

  doctest GPIO

  setup do
    # Verify the test is being run with a clean environment
    assert GPIO.info().pins_open == 0, "Some other test didn't stop cleanly"

    # Verify that the test leaves the environment clean
    on_exit(fn -> assert GPIO.info().pins_open == 0, "Test didn't close all opened GPIOs" end)
    :ok
  end

  # not a real gpiochip, just used for testing
  @gpiochip "gpiochip0"

  # Many of these tests take advantage of the "stub" HAL. The "stub"
  # HAL connects GPIO 0 to 1, 2 to 3, etc. It is useful for testing
  # the interface and much of the NIF source code without needing
  # real hardware.

  test "info returns a map" do
    info = GPIO.info()

    assert is_map(info)
    assert info.name == Circuits.GPIO.CDev
    assert info.pins_open == 0
  end

  describe "line_info/2" do
    test "lines in stub0" do
      for spec <- [4, "pair_2_0", {"stub0", "pair_2_0"}] do
        line_info = GPIO.line_info(spec)

        expected_line_info = %Circuits.GPIO.Line{
          gpio_spec: {"gpiochip0", 4},
          label: "pair_2_0",
          controller: "stub0"
        }

        assert line_info == {:ok, expected_line_info},
               "Unexpected info for #{inspect(spec)} -> #{inspect(line_info)}"
      end
    end

    test "lines in stub1" do
      for spec <- [33, "pair_16_1", {"stub1", "pair_16_1"}] do
        line_info = GPIO.line_info(spec)

        expected_line_info = %Circuits.GPIO.Line{
          gpio_spec: {"gpiochip1", 1},
          label: "pair_16_1",
          controller: "stub1"
        }

        assert line_info == {:ok, expected_line_info},
               "Unexpected info for #{inspect(spec)} -> #{inspect(line_info)}"
      end
    end

    test "nonexistent lines" do
      for spec <- [-1, 65, "pair_100_0", {"stub10", "pair_2_0"}] do
        line_info = GPIO.line_info(spec)

        assert line_info == {:error, :not_found},
               "Unexpected info for #{inspect(spec)} -> #{inspect(line_info)}"
      end
    end
  end

  test "opening and closing a pin gets counted" do
    {:ok, gpio} = GPIO.open({@gpiochip, 1}, :input)
    assert is_struct(gpio, Circuits.GPIO.CDev)

    assert GPIO.info().pins_open == 1

    GPIO.close(gpio)
    assert GPIO.info().pins_open == 0
  end

  test "can get the pin number" do
    {:ok, gpio} = GPIO.open({@gpiochip, 10}, :output)
    assert GPIO.pin(gpio) == 10
    GPIO.close(gpio)
  end

  test "open by pin number returns expected pin number" do
    {:ok, gpio} = GPIO.open(12, :output)
    assert GPIO.pin(gpio) == 12
    GPIO.close(gpio)
  end

  test "open returns errors on invalid pins" do
    # The stub returns error on any pin numbers >= 64
    assert GPIO.open({@gpiochip, 100}, :input) == {:error, :not_found}
  end

  test "gpio refs get garbage collected" do
    assert GPIO.info().pins_open == 0

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

    assert GPIO.info().pins_open == 0
  end

  test "lots of gpio refs can be created" do
    assert GPIO.info().pins_open == 0

    # Expect that the process dying will free up all of the pins
    me = self()
    count = 10_000

    {pid, ref} =
      spawn_monitor(fn ->
        x = Enum.map(1..count, fn _ -> {:ok, _ref} = GPIO.open({@gpiochip, 1}, :input) end)
        ^count = GPIO.info().pins_open
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

    assert GPIO.info().pins_open == 0
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

    assert hd(result) == %Line{
             gpio_spec: {"gpiochip0", 0},
             controller: "stub0",
             label: "pair_0_0"
           }

    assert List.last(result) == %Line{
             gpio_spec: {"gpiochip1", 31},
             controller: "stub1",
             label: "pair_31_1"
           }
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

      assert GPIO.info().pins_open == 1

      GPIO.close(gpio)
      assert GPIO.info().pins_open == 0

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

  test "line_info/2" do
    expected = %Circuits.GPIO.Line{
      gpio_spec: {"gpiochip0", 5},
      label: "pair_2_1",
      controller: "stub0"
    }

    assert GPIO.line_info(5) == {:ok, expected}
    assert GPIO.line_info("pair_2_1") == {:ok, expected}
    assert GPIO.line_info({"gpiochip0", 5}) == {:ok, expected}
    assert GPIO.line_info({"stub0", 5}) == {:ok, expected}
    assert GPIO.line_info({"gpiochip0", "pair_2_1"}) == {:ok, expected}
    assert GPIO.line_info({"stub0", "pair_2_1"}) == {:ok, expected}

    assert GPIO.line_info(-1) == {:error, :not_found}
    assert GPIO.line_info(64) == {:error, :not_found}
    assert GPIO.line_info("something") == {:error, :not_found}
    assert GPIO.line_info({"gpiochip0", 64}) == {:error, :not_found}
    assert GPIO.line_info({"stub0", 64}) == {:error, :not_found}
    assert GPIO.line_info({"gpiochip0", "something"}) == {:error, :not_found}
    assert GPIO.line_info({"stub0", "something"}) == {:error, :not_found}
  end

  test "refresh enumeration cache" do
    bogus_gpio = %Circuits.GPIO.Line{
      gpio_spec: {"gpiochip10", 5},
      label: "not_a_gpio",
      controller: "not_a_controller"
    }

    good_gpio = %Circuits.GPIO.Line{
      gpio_spec: {"gpiochip1", 5},
      label: "pair_18_1",
      controller: "stub1"
    }

    # Set the cache to something bogus and check that it's comes back
    :persistent_term.put(Circuits.GPIO.CDev, [bogus_gpio])
    assert GPIO.line_info("not_a_gpio") == {:ok, bogus_gpio}

    # Now check that the cache gets refreshed when a gpio isn't found
    assert GPIO.line_info("pair_18_1") == {:ok, good_gpio}

    # The bogus GPIO doesn't come back
    assert GPIO.line_info("not_a_gpio") == {:error, :not_found}
  end
end
