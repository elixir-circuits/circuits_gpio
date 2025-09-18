# GPIO Simulator Testing for circuits_gpio

This directory contains a test setup for verifying that the `circuits_gpio` cdev backend works correctly with real GPIO hardware using the Linux `gpio-sim` kernel module.

## Prerequisites

- Linux kernel 5.17+ with `CONFIG_GPIO_SIM` enabled
- `gpio-sim` kernel module available
- `libgpiod` tools (`gpiodetect`, `gpioinfo`, `gpioset`, etc.)
- Root access for configuring gpio-sim

On Ubuntu/Debian:

```bash
sudo apt install linux-modules-extra-$(uname -r) gpiod
```

## Setup

1. Run the setup script to configure gpio-sim:

   ```bash
   ./setup_gpio_sim.sh
   ```

   This script will:

   - Load the `gpio-sim` kernel module
   - Create a GPIO simulator with 8 lines (0-7)
   - Set up a symbolic link `/dev/gpiochip_sim` for consistent access
   - Configure the test environment

2. Verify the setup:

   ```bash
   gpioinfo /dev/gpiochip_sim
   ```

## Running Tests

Run the gpio-sim specific test:

```bash
mix test --include gpio_sim
```

Or run all tests including gpio-sim tests:

```bash
mix test --include gpio_sim test/
```

## What the Test Validates

The test verifies that:

1. **Real Hardware Integration**: The cdev backend works with actual GPIO hardware (gpio-sim), not just the stub backend
2. **Interrupt Setup**: Interrupts can be configured without errors on real hardware
3. **Basic Operations**: GPIO read/write operations work correctly
4. **Resource Management**: GPIO pins are properly opened and closed
5. **Non-root Execution**: Tests run as a regular user (gpio-sim setup requires root, but tests don't)

## Test Limitations

This test focuses on validating the integration with real GPIO hardware rather than testing actual interrupt functionality. For full interrupt testing with stimulus, you would need:

- External hardware to trigger GPIO changes
- Physical connections between GPIO pins
- More complex gpio-sim configurations with automatic connections

## Manual Interrupt Testing

While the automated test doesn't trigger actual interrupts, you can manually test interrupts:

1. Run the following in one terminal to monitor for interrupts:

   ```bash
   mix test --include gpio_sim --trace
   ```

2. In another terminal, trigger GPIO changes:

   ```bash
   # Set GPIO line 1 high
   gpioset gpiochip_sim 1=1

   # Set GPIO line 1 low
   gpioset gpiochip_sim 1=0
   ```

## Cleanup

To remove the gpio-sim configuration:

```bash
./setup_gpio_sim.sh cleanup
```

This will:

- Remove the GPIO simulator configuration
- Unload kernel module (if no other users)
- Clean up device files

## Files

- `gpio_sim_test.exs`: The main test file that validates cdev backend with gpio-sim
- `setup_gpio_sim.sh`: Script to configure gpio-sim for testing
- `README.md`: This documentation file

## Benefits of This Test

1. **Real Hardware Validation**: Unlike the stub backend, this tests actual kernel GPIO subsystem integration
2. **Interrupt Capability Testing**: Verifies that interrupt setup works with real hardware
3. **CI/CD Integration**: Can be automated in CI environments with gpio-sim support
4. **Debugging Aid**: Helps identify issues specific to real hardware vs. stub implementation
