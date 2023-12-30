# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO.Diagnostics do
  @moduledoc """
  Runtime diagnostics

  This module provides simple diagnostics to verify GPIO controller and
  implementation differences. Along with the device that you're using, this is
  super helpful for diagnosing issues since some GPIO features aren't supposed
  to work on some devices.
  """
  alias Circuits.GPIO

  @doc """
  Print a summary of the GPIO diagnostics

  Connect the pins referred to by `gpio_spec1` and `gpio_spec2` together. When
  using the cdev stub implementation, any pair of GPIOs can be used. For
  example, run:

  ```elixir
  Circuits.GPIO.Diagnostics.report({"gpiochip0", 0}, {"gpiochip0", 1})
  ```

  This function is intended for IEx prompt usage. See `run/2` for programmatic
  use.
  """
  @spec report(GPIO.gpio_spec(), GPIO.gpio_spec()) :: boolean
  def report(gpio_spec1, gpio_spec2) do
    results = run(gpio_spec1, gpio_spec2)
    passed = Enum.all?(results, fn {_, result} -> result == :ok end)

    [
      """
      Circuits.GPIO Diagnostics

      GPIO 1: #{inspect(gpio_spec1)}
      GPIO 2: #{inspect(gpio_spec2)}
      Backend: #{inspect(Circuits.GPIO.info()[:name])}

      """,
      Enum.map(results, &pass_text/1),
      "\n\nSpeed test: #{speed_test(gpio_spec1) |> round()} toggles/second (toggle = set to 1, then set to 0)\n\n",
      if(passed, do: "All tests passed", else: "Failed")
    ]
    |> IO.ANSI.format()
    |> IO.puts()

    passed
  end

  defp pass_text({name, :ok}), do: [name, ": ", :green, "PASSED", :reset, "\n"]

  defp pass_text({name, {:error, reason}}),
    do: [name, ": ", :red, "FAILED", :reset, " ", reason, "\n"]

  @doc """
  Run GPIO tests and return a list of the results
  """
  @spec run(GPIO.gpio_spec(), GPIO.gpio_spec()) :: list()
  def run(gpio_spec1, gpio_spec2) do
    tests = [
      {"Writes can be read 1->2", &check_reading_and_writing/3, swap: false},
      {"Writes can be read 2->1", &check_reading_and_writing/3, swap: true},
      {"Can set 0 on open", &check_setting_initial_value/3, value: 0},
      {"Can set 1 on open", &check_setting_initial_value/3, value: 1},
      {"Input interrupts sent", &check_interrupts/3, []},
      {"Interrupt timing sane", &check_interrupt_timing/3, []},
      {"Internal pullup works", &check_pullup/3, []},
      {"Internal pulldown works", &check_pulldown/3, []}
    ]

    tests
    |> Enum.map(&check(&1, gpio_spec1, gpio_spec2))
  end

  @doc """
  Return the number of times a GPIO can be toggled per second

  Disclaimer: There should be a better way than relying on the Circuits.GPIO
  write performance on nearly every device. Write performance shouldn't be
  terrible, though.
  """
  @spec speed_test(GPIO.gpio_spec()) :: float()
  def speed_test(gpio_spec) do
    times = 1000

    {:ok, gpio} = GPIO.open(gpio_spec, :output)
    toggle(gpio, 10)
    {micros, :ok} = :timer.tc(fn -> toggle(gpio, times) end)
    GPIO.close(gpio)

    times / micros * 1_000_000
  end

  defp toggle(gpio, times) do
    Enum.each(1..times, fn _ ->
      GPIO.write(gpio, 0)
      GPIO.write(gpio, 1)
    end)
  end

  defmacrop assert(expr) do
    line = __CALLER__.line

    quote do
      unless unquote(expr) do
        raise "#{unquote(line)}: Assertion failed: #{unquote(Macro.to_string(expr))}"
      end
    end
  end

  defmacrop assert_receive(expected, timeout \\ 500) do
    quote do
      receive do
        unquote(expected) = x ->
          x
      after
        unquote(timeout) ->
          raise "Expected message not received within #{unquote(timeout)}ms: #{unquote(Macro.to_string(expected))}"
      end
    end
  end

  defmacrop refute_receive(unexpected, timeout \\ 50) do
    quote do
      receive do
        unquote(unexpected) ->
          raise "Should not have received message within #{unquote(timeout)}ms: #{unquote(Macro.to_string(unexpected))}"
      after
        unquote(timeout) -> :ok
      end
    end
  end

  defp check({name, test, options}, gpio_spec1, gpio_spec2) do
    {gpio_spec1, gpio_spec2} =
      if options[:swap], do: {gpio_spec2, gpio_spec1}, else: {gpio_spec1, gpio_spec2}

    # Run the tests in a process so that GPIO handles get cleaned up and the process
    # mailbox is empty for interrupt checks.
    t = Task.async(fn -> safe_check(test, gpio_spec1, gpio_spec2, options) end)

    {name, Task.await(t)}
  rescue
    e ->
      {name, {:error, Exception.message(e)}}
  end

  defp safe_check(test, gpio_spec1, gpio_spec2, options) do
    test.(gpio_spec1, gpio_spec2, options)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  @spec check_reading_and_writing(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_reading_and_writing(gpio_spec1, gpio_spec2, _options) do
    {:ok, gpio1} = GPIO.open(gpio_spec1, :output)
    {:ok, gpio2} = GPIO.open(gpio_spec2, :input)

    GPIO.write(gpio1, 0)
    assert GPIO.read(gpio2) == 0

    GPIO.write(gpio1, 1)
    assert GPIO.read(gpio2) == 1

    GPIO.write(gpio1, 0)
    assert GPIO.read(gpio2) == 0

    GPIO.close(gpio1)
    GPIO.close(gpio2)
  end

  @doc false
  @spec check_setting_initial_value(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_setting_initial_value(gpio_spec1, gpio_spec2, options) do
    value = options[:value]
    {:ok, gpio1} = GPIO.open(gpio_spec1, :output, initial_value: value)
    {:ok, gpio2} = GPIO.open(gpio_spec2, :input)

    assert GPIO.read(gpio2) == value

    GPIO.close(gpio1)
    GPIO.close(gpio2)
  end

  @doc false
  @spec check_interrupts(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_interrupts(gpio_spec1, gpio_spec2, _options) do
    {:ok, gpio1} = GPIO.open(gpio_spec1, :output, initial_value: 0)
    {:ok, gpio2} = GPIO.open(gpio_spec2, :input)

    :ok = GPIO.set_interrupts(gpio2, :both)

    # Initial notification
    refute_receive {:circuits_gpio, _spec, _timestamp, _}

    # Toggle enough times to avoid being tricked by something
    # works a few times and then stops.
    for _ <- 1..64 do
      GPIO.write(gpio1, 1)
      _ = assert_receive {:circuits_gpio, ^gpio_spec2, _timestamp, 1}

      GPIO.write(gpio1, 0)
      _ = assert_receive {:circuits_gpio, ^gpio_spec2, _timestamp, 0}
    end

    GPIO.close(gpio1)
    GPIO.close(gpio2)
  end

  @doc false
  @spec check_interrupt_timing(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_interrupt_timing(gpio_spec1, gpio_spec2, _options) do
    {:ok, gpio1} = GPIO.open(gpio_spec1, :output, initial_value: 0)
    {:ok, gpio2} = GPIO.open(gpio_spec2, :input)

    :ok = GPIO.set_interrupts(gpio2, :both)

    # No notifications until something changes
    refute_receive {:circuits_gpio, _, _, _}

    GPIO.write(gpio1, 1)
    {_, _, first_ns, _} = assert_receive {:circuits_gpio, ^gpio_spec2, _, 1}

    GPIO.write(gpio1, 0)
    {_, _, second_ns, _} = assert_receive {:circuits_gpio, ^gpio_spec2, _, 0}

    # No notifications after this
    refute_receive {:circuits_gpio, _, _, _}

    GPIO.close(gpio1)
    GPIO.close(gpio2)

    # Check that the timestamps are ordered and not too far apart.
    assert first_ns < second_ns
    assert second_ns - first_ns < 100_000_000
    assert second_ns - first_ns > 100

    :ok
  end

  @doc false
  @spec check_pullup(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_pullup(gpio_spec1, gpio_spec2, _options) do
    {:ok, gpio1} = GPIO.open(gpio_spec1, :output, initial_value: 0)
    {:ok, gpio2} = GPIO.open(gpio_spec2, :input, pull_mode: :pullup)

    # Check non-pullup case
    assert GPIO.read(gpio2) == 0
    GPIO.write(gpio1, 1)
    assert GPIO.read(gpio2) == 1
    GPIO.write(gpio1, 0)
    assert GPIO.read(gpio2) == 0

    # Check pullup by re-opening gpio1 as an input
    GPIO.close(gpio1)
    {:ok, gpio1} = GPIO.open(gpio_spec1, :input)

    assert GPIO.read(gpio2) == 1

    GPIO.close(gpio1)
    GPIO.close(gpio2)
  end

  @doc false
  @spec check_pulldown(GPIO.gpio_spec(), GPIO.gpio_spec(), keyword()) :: :ok
  def check_pulldown(gpio_spec1, gpio_spec2, _options) do
    {:ok, gpio1} = GPIO.open(gpio_spec1, :output, initial_value: 1)
    {:ok, gpio2} = GPIO.open(gpio_spec2, :input, pull_mode: :pulldown)

    # Check non-pullup case
    assert GPIO.read(gpio2) == 1
    GPIO.write(gpio1, 0)
    assert GPIO.read(gpio2) == 0
    GPIO.write(gpio1, 1)
    assert GPIO.read(gpio2) == 1

    # Check pulldown by re-opening gpio1 as an input
    GPIO.close(gpio1)
    {:ok, gpio1} = GPIO.open(gpio_spec1, :input)

    assert GPIO.read(gpio2) == 0

    GPIO.close(gpio1)
    GPIO.close(gpio2)
  end
end
