# SPDX-FileCopyrightText: 2025 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule VirtualGPIOTest do
  use ExUnit.Case, async: false

  alias Circuits.GPIO

  setup do
    # Clean up any existing state
    VirtualGPIO.State.stop()

    # Set the virtual GPIO backend
    old_backend = Application.get_env(:circuits_gpio, :backend)

    Application.put_env(:circuits_gpio, :backend, {VirtualGPIO.Backend, []})

    on_exit(fn ->
      VirtualGPIO.State.stop()

      if old_backend do
        Application.put_env(:circuits_gpio, :backend, old_backend)
      else
        Application.delete_env(:circuits_gpio, :backend)
      end
    end)

    :ok
  end

  describe "backend enumeration" do
    test "enumerate returns two GPIOs" do
      gpios = GPIO.enumerate()

      assert length(gpios) == 2

      output_gpio = Enum.find(gpios, &(&1.label == "VIRTUAL_OUTPUT"))
      input_gpio = Enum.find(gpios, &(&1.label == "VIRTUAL_INPUT"))

      assert output_gpio == %{
               location: {"virtual_chip", 0},
               controller: "virtual_chip",
               label: "VIRTUAL_OUTPUT"
             }

      assert input_gpio == %{
               location: {"virtual_chip", 1},
               controller: "virtual_chip",
               label: "VIRTUAL_INPUT"
             }
    end

    test "identifiers works with controller/line tuple" do
      {:ok, identifiers} = GPIO.identifiers({"virtual_chip", 0})

      assert identifiers == %{
               location: {"virtual_chip", 0},
               controller: "virtual_chip",
               label: "VIRTUAL_OUTPUT"
             }

      {:ok, identifiers} = GPIO.identifiers({"virtual_chip", 1})

      assert identifiers == %{
               location: {"virtual_chip", 1},
               controller: "virtual_chip",
               label: "VIRTUAL_INPUT"
             }
    end

    test "identifiers works with labels" do
      {:ok, identifiers} = GPIO.identifiers("VIRTUAL_OUTPUT")

      assert identifiers == %{
               location: {"virtual_chip", 0},
               controller: "virtual_chip",
               label: "VIRTUAL_OUTPUT"
             }

      {:ok, identifiers} = GPIO.identifiers("VIRTUAL_INPUT")

      assert identifiers == %{
               location: {"virtual_chip", 1},
               controller: "virtual_chip",
               label: "VIRTUAL_INPUT"
             }
    end

    test "identifiers returns error for unknown GPIO" do
      assert {:error, :not_found} = GPIO.identifiers({"virtual_chip", 2})
      assert {:error, :not_found} = GPIO.identifiers("UNKNOWN_GPIO")
    end
  end

  describe "GPIO status" do
    test "status returns correct information" do
      {:ok, status} = GPIO.status({"virtual_chip", 0})

      assert status == %{
               consumer: nil,
               direction: :output,
               pull_mode: :not_set
             }

      {:ok, status} = GPIO.status({"virtual_chip", 1})

      assert status == %{
               consumer: nil,
               direction: :input,
               pull_mode: :not_set
             }
    end

    test "status works with labels" do
      {:ok, status} = GPIO.status("VIRTUAL_OUTPUT")

      assert status == %{
               consumer: nil,
               direction: :output,
               pull_mode: :not_set
             }

      {:ok, status} = GPIO.status("VIRTUAL_INPUT")

      assert status == %{
               consumer: nil,
               direction: :input,
               pull_mode: :not_set
             }
    end
  end

  describe "GPIO opening and direction restrictions" do
    test "can open output GPIO as output" do
      assert {:ok, handle} = GPIO.open({"virtual_chip", 0}, :output)
      assert is_struct(handle, VirtualGPIO.Handle)
      assert handle.gpio == 0
      assert handle.direction == :output

      GPIO.close(handle)
    end

    test "can open input GPIO as input" do
      assert {:ok, handle} = GPIO.open({"virtual_chip", 1}, :input)
      assert is_struct(handle, VirtualGPIO.Handle)
      assert handle.gpio == 1
      assert handle.direction == :input

      GPIO.close(handle)
    end

    test "cannot open output GPIO as input" do
      assert {:error, :invalid_direction} = GPIO.open({"virtual_chip", 0}, :input)
    end

    test "cannot open input GPIO as output" do
      assert {:error, :invalid_direction} = GPIO.open({"virtual_chip", 1}, :output)
    end

    test "can open using labels" do
      assert {:ok, output_handle} = GPIO.open("VIRTUAL_OUTPUT", :output)
      assert {:ok, input_handle} = GPIO.open("VIRTUAL_INPUT", :input)

      GPIO.close(output_handle)
      GPIO.close(input_handle)
    end

    test "initial_value option works for output" do
      # Test initial value of 0 (default)
      {:ok, output} = GPIO.open({"virtual_chip", 0}, :output)
      {:ok, input} = GPIO.open({"virtual_chip", 1}, :input)

      assert GPIO.read(input) == 0

      GPIO.close(output)
      GPIO.close(input)

      # Test initial value of 1
      {:ok, output} = GPIO.open({"virtual_chip", 0}, :output, initial_value: 1)
      {:ok, input} = GPIO.open({"virtual_chip", 1}, :input)

      assert GPIO.read(input) == 1

      GPIO.close(output)
      GPIO.close(input)
    end
  end

  describe "virtual connection behavior" do
    test "write to output appears on input" do
      {:ok, output} = GPIO.open({"virtual_chip", 0}, :output)
      {:ok, input} = GPIO.open({"virtual_chip", 1}, :input)

      # Initial state should be 0
      assert GPIO.read(input) == 0

      # Write 1 to output
      GPIO.write(output, 1)
      assert GPIO.read(input) == 1

      # Write 0 to output
      GPIO.write(output, 0)
      assert GPIO.read(input) == 0

      # Write 1 again
      GPIO.write(output, 1)
      assert GPIO.read(input) == 1

      GPIO.close(output)
      GPIO.close(input)
    end

    test "reading from output returns last written value" do
      {:ok, output} = GPIO.open({"virtual_chip", 0}, :output)

      # Initial value should be 0
      assert GPIO.read(output) == 0

      # Write and read back
      GPIO.write(output, 1)
      assert GPIO.read(output) == 1

      GPIO.write(output, 0)
      assert GPIO.read(output) == 0

      GPIO.close(output)
    end

    test "cannot write to input GPIO" do
      {:ok, input} = GPIO.open({"virtual_chip", 1}, :input)

      assert {:error, :read_only} = GPIO.write(input, 1)
      assert {:error, :read_only} = GPIO.write(input, 0)

      GPIO.close(input)
    end

    test "multiple opens share the same virtual connection" do
      {:ok, output1} = GPIO.open({"virtual_chip", 0}, :output)
      {:ok, output2} = GPIO.open({"virtual_chip", 0}, :output)
      {:ok, input1} = GPIO.open({"virtual_chip", 1}, :input)
      {:ok, input2} = GPIO.open({"virtual_chip", 1}, :input)

      # Write with first output handle
      GPIO.write(output1, 1)

      # Both input handles should read the same value
      assert GPIO.read(input1) == 1
      assert GPIO.read(input2) == 1

      # Write with second output handle
      GPIO.write(output2, 0)

      # Both input handles should read the new value
      assert GPIO.read(input1) == 0
      assert GPIO.read(input2) == 0

      GPIO.close(output1)
      GPIO.close(output2)
      GPIO.close(input1)
      GPIO.close(input2)
    end
  end

  describe "handle protocol implementation" do
    test "set_direction works for valid directions" do
      {:ok, output} = GPIO.open({"virtual_chip", 0}, :output)
      {:ok, input} = GPIO.open({"virtual_chip", 1}, :input)

      assert :ok = GPIO.set_direction(output, :output)
      assert :ok = GPIO.set_direction(input, :input)

      GPIO.close(output)
      GPIO.close(input)
    end

    test "set_direction fails for invalid directions" do
      {:ok, output} = GPIO.open({"virtual_chip", 0}, :output)
      {:ok, input} = GPIO.open({"virtual_chip", 1}, :input)

      assert {:error, :invalid_direction} = GPIO.set_direction(output, :input)
      assert {:error, :invalid_direction} = GPIO.set_direction(input, :output)

      GPIO.close(output)
      GPIO.close(input)
    end

    test "set_pull_mode works for input, fails for output" do
      {:ok, output} = GPIO.open({"virtual_chip", 0}, :output)
      {:ok, input} = GPIO.open({"virtual_chip", 1}, :input)

      assert :ok = GPIO.set_pull_mode(input, :pullup)
      assert :ok = GPIO.set_pull_mode(input, :pulldown)
      assert :ok = GPIO.set_pull_mode(input, :none)

      assert {:error, :not_supported} = GPIO.set_pull_mode(output, :pullup)

      GPIO.close(output)
      GPIO.close(input)
    end

    test "set_interrupts returns not supported" do
      {:ok, input} = GPIO.open({"virtual_chip", 1}, :input)

      assert {:error, :not_supported} = GPIO.set_interrupts(input, :rising, [])

      GPIO.close(input)
    end

    test "close always succeeds" do
      {:ok, output} = GPIO.open({"virtual_chip", 0}, :output)
      {:ok, input} = GPIO.open({"virtual_chip", 1}, :input)

      assert :ok = GPIO.close(output)
      assert :ok = GPIO.close(input)
    end
  end

  describe "backend info" do
    test "backend_info returns module information" do
      info = VirtualGPIO.Backend.backend_info()

      assert info.name == VirtualGPIO.Backend
      assert info.description == "Virtual GPIO backend for testing"
    end
  end

  describe "edge cases and error handling" do
    test "opening non-existent GPIO returns error" do
      assert {:error, :not_found} = GPIO.open({"virtual_chip", 2}, :output)
      assert {:error, :not_found} = GPIO.open({"other_chip", 0}, :output)
      assert {:error, :not_found} = GPIO.open("UNKNOWN_LABEL", :output)
    end

    test "state persists across handle close/reopen" do
      # Open handles and set a value
      {:ok, output} = GPIO.open({"virtual_chip", 0}, :output)
      {:ok, input} = GPIO.open({"virtual_chip", 1}, :input)

      GPIO.write(output, 1)
      assert GPIO.read(input) == 1

      # Close handles
      GPIO.close(output)
      GPIO.close(input)

      # Reopen and verify state persisted
      {:ok, input2} = GPIO.open({"virtual_chip", 1}, :input)
      assert GPIO.read(input2) == 1

      GPIO.close(input2)
    end
  end
end
