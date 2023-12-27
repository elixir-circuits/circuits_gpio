# SPDX-FileCopyrightText: 2023 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule Circuits.GPIO2.Diagnostics do
  @moduledoc """
  Runtime diagnostics

  This module provides simple diagnostics to verify GPIO controller
  and implementation differences. Along with the device that you're
  using, this is super helpful for diagnosing issues since some GPIO
  features aren't supposed to work on some devices.
  """
  alias Circuits.GPIO2

  @doc """
  Print a summary of the GPIO diagnostics

  Connect the pins referred to by `gpio_spec1` and `gpio_spec2` together. When using
  the cdev stub implementation, any pair of GPIOs can be used. For example, run:

  ```elixir
  Circuits.GPIO2.Diagnostics.report({"gpiochip0", 0}, {"gpiochip0", 1})
  ```

  This function is intended for IEx prompt usage. See `run/2` for programmatic use.
  """
  @spec report(Circuits.GPIO2.gpio_spec(), Circuits.GPIO2.gpio_spec()) :: boolean
  def report(gpio_spec1, gpio_spec2) do
    results = run(gpio_spec1, gpio_spec2)
    passed = Enum.all?(results, fn {_, result} -> result == :ok end)

    [
      """
      Circuits.GPIO Diagnostics

      GPIO 1: #{inspect(gpio_spec1)}
      GPIO 2: #{inspect(gpio_spec2)}

      """,
      Enum.map(results, &pass_text/1),
      "\n\nSpeed test: #{speed_test(gpio_spec1)} toggles/second\n\n",
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
  @spec run(Circuits.GPIO2.gpio_spec(), Circuits.GPIO2.gpio_spec()) :: list()
  def run(gpio_spec1, gpio_spec2) do
    tests = [
      {"Writes can be read 1->2", &check_reading_and_writing/3, swap: false},
      {"Writes can be read 2->1", &check_reading_and_writing/3, swap: true},
      {"Can set 0 on open", &check_setting_initial_value/3, value: 0},
      {"Can set 1 on open", &check_setting_initial_value/3, value: 1},
      {"Preserves 0 across opens", &check_preserves_value/3, value: 0},
      {"Preserves 1 across opens", &check_preserves_value/3, value: 1},
      {"Input interrupts sent", &check_interrupts/3, []},
      {"Internal pullup works", &check_pullup/3, []},
      {"Internal pulldown works", &check_pulldown/3, []}
    ]

    tests
    |> Enum.map(&check(&1, gpio_spec1, gpio_spec2))
  end

  @doc """
  Return the number of times a GPIO can be toggled per second

  Disclaimer: There should be a better way than relying on the Circuits.GPIO write performance
  on nearly every device. Write performance shouldn't be terrible, though.
  """
  @spec speed_test(Circuits.GPIO2.gpio_spec()) :: float()
  def speed_test(gpio_spec) do
    times = 10000

    {:ok, gpio} = GPIO2.open(gpio_spec, :output)
    toggle(gpio, 1000)
    {micros, :ok} = :timer.tc(fn -> toggle(gpio, times) end)
    GPIO2.close(gpio)

    times / micros * 1_000_000
  end

  defp toggle(gpio, times) do
    Enum.each(1..times, fn _ ->
      GPIO2.write(gpio, 0)
      GPIO2.write(gpio, 1)
    end)
  end

  defmacrop assert(expr) do
    quote do
      unless unquote(expr) do
        raise "Assertion failed: #{unquote(Macro.to_string(expr))}"
      end
    end
  end

  defmacrop assert_receive(expected_message, timeout \\ 100) do
    quote do
      receive do
        unquote(expected_message) ->
          :ok
      after
        unquote(timeout) ->
          raise "Expected message not received within #{unquote(timeout)}ms: #{unquote(Macro.to_string(expected_message))}"
      end
    end
  end

  defp check({name, test, options}, gpio_spec1, gpio_spec2) do
    if options[:swap] do
      {name, test.(gpio_spec2, gpio_spec1, options)}
    else
      {name, test.(gpio_spec1, gpio_spec2, options)}
    end
  rescue
    e ->
      {name, {:error, Exception.message(e)}}
  end

  defp check_reading_and_writing(gpio_spec1, gpio_spec2, _options) do
    {:ok, gpio1} = GPIO2.open(gpio_spec1, :output)
    {:ok, gpio2} = GPIO2.open(gpio_spec2, :input)

    GPIO2.write(gpio1, 0)
    assert GPIO2.read(gpio2) == 0

    GPIO2.write(gpio1, 1)
    assert GPIO2.read(gpio2) == 1

    GPIO2.write(gpio1, 0)
    assert GPIO2.read(gpio2) == 0

    GPIO2.close(gpio1)
    GPIO2.close(gpio2)
  end

  defp check_setting_initial_value(gpio_spec1, gpio_spec2, options) do
    value = options[:value]
    {:ok, gpio1} = GPIO2.open(gpio_spec1, :output, initial_value: value)
    {:ok, gpio2} = GPIO2.open(gpio_spec2, :input)

    assert GPIO2.read(gpio2) == value
    assert GPIO2.read(gpio1) == value

    GPIO2.close(gpio1)
    GPIO2.close(gpio2)
  end

  defp check_preserves_value(gpio_spec1, gpio_spec2, options) do
    value = options[:value]
    {:ok, gpio1} = GPIO2.open(gpio_spec1, :output)
    GPIO2.write(gpio1, value)
    GPIO2.close(gpio1)

    {:ok, gpio1} = GPIO2.open(gpio_spec1, :output)
    {:ok, gpio2} = GPIO2.open(gpio_spec2, :input)

    assert GPIO2.read(gpio2) == value
    assert GPIO2.read(gpio1) == value

    GPIO2.close(gpio1)
    GPIO2.close(gpio2)
  end

  defp check_interrupts(gpio_spec1, gpio_spec2, _options) do
    {:ok, gpio1} = GPIO2.open(gpio_spec1, :output, initial_value: 0)
    {:ok, gpio2} = GPIO2.open(gpio_spec2, :input)

    :ok = GPIO2.set_interrupts(gpio2, :both)
    assert_receive {:circuits_gpio2, ^gpio_spec2, _timestamp, 0}

    GPIO2.write(gpio1, 1)
    assert_receive {:circuits_gpio2, ^gpio_spec2, _timestamp, 1}

    GPIO2.write(gpio1, 0)
    assert_receive {:circuits_gpio2, ^gpio_spec2, _timestamp, 0}

    GPIO2.close(gpio1)
    GPIO2.close(gpio2)
  end

  defp check_pullup(gpio_spec1, gpio_spec2, _options) do
    {:ok, gpio1} = GPIO2.open(gpio_spec1, :output, initial_value: 0)
    {:ok, gpio2} = GPIO2.open(gpio_spec2, :input, pull_mode: :pullup)

    # Check non-pullup case
    assert GPIO2.read(gpio2) == 0
    GPIO2.write(gpio1, 1)
    assert GPIO2.read(gpio2) == 1
    GPIO2.write(gpio1, 0)
    assert GPIO2.read(gpio2) == 0

    # Check pullup by re-opening gpio1 as an input
    GPIO2.close(gpio1)
    {:ok, gpio1} = GPIO2.open(gpio_spec1, :input)

    assert GPIO2.read(gpio2) == 1

    GPIO2.close(gpio1)
    GPIO2.close(gpio2)
  end

  defp check_pulldown(gpio_spec1, gpio_spec2, _options) do
    {:ok, gpio1} = GPIO2.open(gpio_spec1, :output, initial_value: 1)
    {:ok, gpio2} = GPIO2.open(gpio_spec2, :input, pull_mode: :pulldown)

    # Check non-pullup case
    assert GPIO2.read(gpio2) == 1
    GPIO2.write(gpio1, 0)
    assert GPIO2.read(gpio2) == 0
    GPIO2.write(gpio1, 1)
    assert GPIO2.read(gpio2) == 1

    # Check pulldown by re-opening gpio1 as an input
    GPIO2.close(gpio1)
    {:ok, gpio1} = GPIO2.open(gpio_spec1, :input)

    assert GPIO2.read(gpio2) == 0

    GPIO2.close(gpio1)
    GPIO2.close(gpio2)
  end
end
