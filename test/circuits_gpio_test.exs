# SPDX-FileCopyrightText: 2018 Frank Hunleth, Mark Sebald, Matt Ludwigs
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO2Test do
  use ExUnit.Case
  alias Circuits.GPIO2
  alias Circuits.GPIO2.Line

  setup do
    # Verify the test is being run with a clean environment
    assert GPIO2.info().pins_open == 0, "Some other test didn't stop cleanly"

    # Verify that the test leaves the environment clean
    on_exit(fn -> assert GPIO2.info().pins_open == 0, "Test didn't close all opened GPIOs" end)
    :ok
  end

  # not a real gpiochip, just used for testing
  @gpiochip "gpiochip0"

  # Many of these tests take advantage of the "stub" HAL. The "stub"
  # HAL connects GPIO 0 to 1, 2 to 3, etc. It is useful for testing
  # the interface and much of the NIF source code without needing
  # real hardware.

  test "info returns a map" do
    info = GPIO2.info()

    assert is_map(info)
    assert info.name == Circuits.GPIO2.CDev
    assert info.pins_open == 0
  end

  test "opening and closing a pin gets counted" do
    {:ok, gpio} = GPIO2.open({@gpiochip, 1}, :input)
    assert is_struct(gpio, Circuits.GPIO2.CDev)

    assert GPIO2.info().pins_open == 1

    GPIO2.close(gpio)
    assert GPIO2.info().pins_open == 0
  end

  test "can get the pin number" do
    {:ok, gpio} = GPIO2.open({@gpiochip, 10}, :output)
    assert GPIO2.pin(gpio) == 10
    GPIO2.close(gpio)
  end

  test "open returns errors on invalid pins" do
    # The stub returns error on any pin numbers >= 64
    assert GPIO2.open({@gpiochip, 100}, :input) == {:error, :no_gpio}
  end

  test "gpio refs get garbage collected" do
    assert GPIO2.info().pins_open == 0

    # Expect that the process dying will free up the pin
    me = self()

    spawn_link(fn ->
      {:ok, _ref} = GPIO2.open({@gpiochip, 1}, :input)
      send(me, :done)
    end)

    assert_receive :done

    # Wait a fraction of a second to allow GC to run since there's
    # a race between the send and the GC actually running.
    Process.sleep(10)

    assert GPIO2.info().pins_open == 0
  end

  test "lots of gpio refs can be created" do
    assert GPIO2.info().pins_open == 0

    # Expect that the process dying will free up all of the pins
    me = self()
    count = 10_000

    {pid, ref} =
      spawn_monitor(fn ->
        x = Enum.map(1..count, fn _ -> {:ok, _ref} = GPIO2.open({@gpiochip, 1}, :input) end)
        ^count = GPIO2.info().pins_open
        send(me, {:done, length(x)})
      end)

    # Wait to allow spawned task to complete
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

    refute Process.alive?(pid)
    assert_receive {:done, ^count}

    # Wait a fraction of a second to allow GC to run since there's
    # a race between the send and the GC actually running.
    Process.sleep(10)

    assert GPIO2.info().pins_open == 0
  end

  test "can read and write gpio" do
    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO2.open({@gpiochip, 1}, :input)

    :ok = GPIO2.write(gpio0, 1)
    assert GPIO2.read(gpio1) == 1
    :ok = GPIO2.write(gpio0, 0)
    assert GPIO2.read(gpio1) == 0

    GPIO2.close(gpio0)
    GPIO2.close(gpio1)
  end

  test "can set direction" do
    {:ok, gpio} = GPIO2.open({@gpiochip, 0}, :output)
    assert GPIO2.set_direction(gpio, :input) == :ok
    assert GPIO2.set_direction(gpio, :output) == :ok
    GPIO2.close(gpio)
  end

  test "can set pull mode" do
    {:ok, gpio} = GPIO2.open({@gpiochip, 1}, :input)
    assert GPIO2.set_pull_mode(gpio, :not_set) == :ok
    assert GPIO2.set_pull_mode(gpio, :none) == :ok
    assert GPIO2.set_pull_mode(gpio, :pullup) == :ok
    assert GPIO2.set_pull_mode(gpio, :pulldown) == :ok
    GPIO2.close(gpio)
  end

  test "can set pull mode in open" do
    {:ok, gpio} = GPIO2.open({@gpiochip, 1}, :input, pull_mode: :pullup)
    GPIO2.close(gpio)
  end

  test "ignores unknown open options" do
    {:ok, gpio} = GPIO2.open({@gpiochip, 1}, :input, bogus: true)
    GPIO2.close(gpio)
  end

  test "initial interrupt on set_interrupts" do
    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO2.open({@gpiochip, 1}, :input)

    :ok = GPIO2.set_interrupts(gpio1, :both)
    assert_receive {:circuits_gpio2, 1, _timestamp, 0}

    GPIO2.close(gpio0)
    GPIO2.close(gpio1)
  end

  test "interrupts on both edges" do
    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO2.open({@gpiochip, 1}, :input)

    :ok = GPIO2.set_interrupts(gpio1, :both)
    assert_receive {:circuits_gpio2, 1, _timestamp, 0}

    :ok = GPIO2.write(gpio0, 1)
    assert_receive {:circuits_gpio2, 1, _timestamp, 1}

    :ok = GPIO2.write(gpio0, 0)
    assert_receive {:circuits_gpio2, 1, _timestamp, 0}

    GPIO2.close(gpio0)
    GPIO2.close(gpio1)
  end

  test "interrupts on falling edges" do
    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO2.open({@gpiochip, 1}, :input)

    :ok = GPIO2.set_interrupts(gpio1, :falling)
    assert_receive {:circuits_gpio2, 1, _timestamp, 0}

    :ok = GPIO2.write(gpio0, 1)
    refute_receive {:circuits_gpio2, 1, _timestamp, 1}

    :ok = GPIO2.write(gpio0, 0)
    assert_receive {:circuits_gpio2, 1, _timestamp, 0}

    GPIO2.close(gpio0)
    GPIO2.close(gpio1)
  end

  test "interrupts on rising edges" do
    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO2.open({@gpiochip, 1}, :input)

    :ok = GPIO2.set_interrupts(gpio1, :rising)
    refute_receive {:circuits_gpio2, 1, _timestamp, 0}

    :ok = GPIO2.write(gpio0, 1)
    assert_receive {:circuits_gpio2, 1, _timestamp, 1}

    :ok = GPIO2.write(gpio0, 0)
    refute_receive {:circuits_gpio2, 1, _timestamp, 0}

    GPIO2.close(gpio0)
    GPIO2.close(gpio1)
  end

  test "can disable interrupts" do
    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO2.open({@gpiochip, 1}, :input)

    :ok = GPIO2.set_interrupts(gpio1, :both)
    assert_receive {:circuits_gpio2, 1, _timestamp, 0}

    :ok = GPIO2.write(gpio0, 1)
    assert_receive {:circuits_gpio2, 1, _timestamp, 1}

    :ok = GPIO2.set_interrupts(gpio1, :none)
    :ok = GPIO2.write(gpio0, 0)
    refute_receive {:circuits_gpio2, 1, _timestamp, 0}

    GPIO2.close(gpio0)
    GPIO2.close(gpio1)
  end

  test "no interrupts after closing" do
    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output)
    {:ok, gpio1} = GPIO2.open({@gpiochip, 1}, :input)

    :ok = GPIO2.set_interrupts(gpio1, :both)
    assert_receive {:circuits_gpio2, 1, _timestamp, 0}

    :ok = GPIO2.write(gpio0, 1)
    assert_receive {:circuits_gpio2, 1, _timestamp, 1}

    GPIO2.close(gpio1)
    Process.sleep(10)

    :ok = GPIO2.write(gpio0, 0)
    refute_receive {:circuits_gpio2, 1, _timestamp, 0}

    GPIO2.close(gpio0)
  end

  test "opening as an output doesn't change the output by default" do
    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output)
    :ok = GPIO2.write(gpio0, 1)
    GPIO2.close(gpio0)

    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output)
    assert GPIO2.read(gpio0) == 1
    :ok = GPIO2.write(gpio0, 0)
    GPIO2.close(gpio0)

    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output)
    assert GPIO2.read(gpio0) == 0
    GPIO2.close(gpio0)
  end

  test "can set the output on open" do
    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output, initial_value: 1)
    assert GPIO2.read(gpio0) == 1
    GPIO2.close(gpio0)

    {:ok, gpio0} = GPIO2.open({@gpiochip, 0}, :output, initial_value: 0)
    assert GPIO2.read(gpio0) == 0
    GPIO2.close(gpio0)
  end

  test "can enumerate GPIOs" do
    result = GPIO2.enumerate()
    assert length(result) == 32

    assert hd(result) == %Line{
             line_spec: {"gpiochip0", 0},
             controller: "gpiochip0",
             label: {"stub", "pair_0_0"}
           }
  end

  test "unloading NIF" do
    # The theory here is that there shouldn't be a crash if this is reloaded a
    # few times.
    for _times <- 1..10 do
      assert {:module, Circuits.GPIO2} == :code.ensure_loaded(Circuits.GPIO2)
      assert {:module, Circuits.GPIO2.Nif} == :code.ensure_loaded(Circuits.GPIO2.Nif)

      # Try running something to verify that it works.
      {:ok, gpio} = GPIO2.open({@gpiochip, 1}, :input)
      assert is_struct(gpio, Circuits.GPIO2.CDev)

      assert GPIO2.info().pins_open == 1

      GPIO2.close(gpio)
      assert GPIO2.info().pins_open == 0

      assert true == :code.delete(Circuits.GPIO2.Nif)
      assert true == :code.delete(Circuits.GPIO2)

      # The purge will call the unload which can be verified by turning DEBUG on
      # in the C code.
      assert false == :code.purge(Circuits.GPIO2.Nif)
      assert false == :code.purge(Circuits.GPIO2)
    end
  end
end
