defmodule Circuits.GPIOTest do
  use ExUnit.Case
  alias Circuits.GPIO

  # Many of these tests take advantage of the "stub" HAL. The "stub"
  # HAL connects GPIO 0 to 1, 2 to 3, etc. It is useful for testing
  # the interface and much of the NIF source code without needing
  # real hardware.

  test "info returns a map" do
    info = GPIO.info()

    assert is_map(info)
    assert info.name == :stub
    assert info.pins_open == 0
  end

  test "opening and closing a pin gets counted" do
    {:ok, gpio} = GPIO.open(1, :input)
    assert is_reference(gpio)

    assert GPIO.info().pins_open == 1

    GPIO.close(gpio)
    assert GPIO.info().pins_open == 0
  end

  test "can get the pin number" do
    {:ok, gpio} = GPIO.open(10, :output)
    assert GPIO.pin(gpio) == 10
    GPIO.close(gpio)
  end

  test "open returns errors on invalid pins" do
    # The stub returns error on any pin numbers >= 64
    assert GPIO.open(100, :input) == {:error, :no_gpio}
  end

  test "gpio refs get garbage collected" do
    assert GPIO.info().pins_open == 0

    # Expect that the process dying will free up the pin
    me = self()

    spawn_link(fn ->
      {:ok, _ref} = GPIO.open(1, :input)
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
    count = 10000

    spawn_link(fn ->
      x = Enum.map(1..count, fn _ -> {:ok, _ref} = GPIO.open(1, :input) end)
      ^count = GPIO.info().pins_open
      send(me, {:done, length(x)})
    end)

    # Wait a tehth of a second to allow spawned task to complete
    Process.sleep(100)

    assert_receive {:done, ^count}

    # Wait a fraction of a second to allow GC to run since there's
    # a race between the send and the GC actually running.
    Process.sleep(10)

    assert GPIO.info().pins_open == 0
  end

  test "can read and write gpio" do
    {:ok, gpio0} = GPIO.open(0, :output)
    {:ok, gpio1} = GPIO.open(1, :input)

    :ok = GPIO.write(gpio0, 1)
    assert GPIO.read(gpio1) == 1
    :ok = GPIO.write(gpio0, 0)
    assert GPIO.read(gpio1) == 0

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "can set direction" do
    {:ok, gpio} = GPIO.open(0, :output)
    assert GPIO.set_direction(gpio, :input) == :ok
    assert GPIO.set_direction(gpio, :output) == :ok
    GPIO.close(gpio)
  end

  test "can set pull mode" do
    {:ok, gpio} = GPIO.open(1, :input)
    assert GPIO.set_pull_mode(gpio, :not_set) == :ok
    assert GPIO.set_pull_mode(gpio, :none) == :ok
    assert GPIO.set_pull_mode(gpio, :pullup) == :ok
    assert GPIO.set_pull_mode(gpio, :pulldown) == :ok
    GPIO.close(gpio)
  end

  test "can set pull mode in open" do
    {:ok, gpio} = GPIO.open(1, :input, pull_mode: :pullup)
    GPIO.close(gpio)
  end

  test "raises on bad open option" do
    assert_raise ArgumentError, fn -> GPIO.open(1, :input, bogus: true) end
  end

  test "initial interrupt on set_interrupts" do
    {:ok, gpio0} = GPIO.open(0, :output)
    {:ok, gpio1} = GPIO.open(1, :input)

    :ok = GPIO.set_interrupts(gpio1, :both)
    assert_receive {:circuits_gpio, 1, _timestamp, 0}

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "interrupts on both edges" do
    {:ok, gpio0} = GPIO.open(0, :output)
    {:ok, gpio1} = GPIO.open(1, :input)

    :ok = GPIO.set_interrupts(gpio1, :both)
    assert_receive {:circuits_gpio, 1, _timestamp, 0}

    :ok = GPIO.write(gpio0, 1)
    assert_receive {:circuits_gpio, 1, _timestamp, 1}

    :ok = GPIO.write(gpio0, 0)
    assert_receive {:circuits_gpio, 1, _timestamp, 0}

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "interrupts on falling edges" do
    {:ok, gpio0} = GPIO.open(0, :output)
    {:ok, gpio1} = GPIO.open(1, :input)

    :ok = GPIO.set_interrupts(gpio1, :falling)
    assert_receive {:circuits_gpio, 1, _timestamp, 0}

    :ok = GPIO.write(gpio0, 1)
    refute_receive {:circuits_gpio, 1, _timestamp, 1}

    :ok = GPIO.write(gpio0, 0)
    assert_receive {:circuits_gpio, 1, _timestamp, 0}

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "interrupts on rising edges" do
    {:ok, gpio0} = GPIO.open(0, :output)
    {:ok, gpio1} = GPIO.open(1, :input)

    :ok = GPIO.set_interrupts(gpio1, :rising)
    refute_receive {:circuits_gpio, 1, _timestamp, 0}

    :ok = GPIO.write(gpio0, 1)
    assert_receive {:circuits_gpio, 1, _timestamp, 1}

    :ok = GPIO.write(gpio0, 0)
    refute_receive {:circuits_gpio, 1, _timestamp, 0}

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "can disable interrupts" do
    {:ok, gpio0} = GPIO.open(0, :output)
    {:ok, gpio1} = GPIO.open(1, :input)

    :ok = GPIO.set_interrupts(gpio1, :both)
    assert_receive {:circuits_gpio, 1, _timestamp, 0}

    :ok = GPIO.write(gpio0, 1)
    assert_receive {:circuits_gpio, 1, _timestamp, 1}

    :ok = GPIO.set_interrupts(gpio1, :none)
    :ok = GPIO.write(gpio0, 0)
    refute_receive {:circuits_gpio, 1, _timestamp, 0}

    GPIO.close(gpio0)
    GPIO.close(gpio1)
  end

  test "no interrupts after closing" do
    {:ok, gpio0} = GPIO.open(0, :output)
    {:ok, gpio1} = GPIO.open(1, :input)

    :ok = GPIO.set_interrupts(gpio1, :both)
    assert_receive {:circuits_gpio, 1, _timestamp, 0}

    :ok = GPIO.write(gpio0, 1)
    assert_receive {:circuits_gpio, 1, _timestamp, 1}

    GPIO.close(gpio1)
    Process.sleep(10)

    :ok = GPIO.write(gpio0, 0)
    refute_receive {:circuits_gpio, 1, _timestamp, 0}

    GPIO.close(gpio0)
  end

  test "opening as an output doesn't change the output by default" do
    {:ok, gpio0} = GPIO.open(0, :output)
    :ok = GPIO.write(gpio0, 1)
    GPIO.close(gpio0)

    {:ok, gpio0} = GPIO.open(0, :output)
    assert GPIO.read(gpio0) == 1
    :ok = GPIO.write(gpio0, 0)
    GPIO.close(gpio0)

    {:ok, gpio0} = GPIO.open(0, :output)
    assert GPIO.read(gpio0) == 0
    GPIO.close(gpio0)
  end

  test "can set the output on open" do
    {:ok, gpio0} = GPIO.open(0, :output, initial_value: 1)
    assert GPIO.read(gpio0) == 1
    GPIO.close(gpio0)

    {:ok, gpio0} = GPIO.open(0, :output, initial_value: 0)
    assert GPIO.read(gpio0) == 0
    GPIO.close(gpio0)
  end
end
