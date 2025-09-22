#!/bin/bash

# SPDX-FileCopyrightText: 2025 Frank Hunleth
# SPDX-License-Identifier: Apache-2.0

# GPIO Simulator Setup Script for circuits_gpio testing
# This script sets up gpio-sim for testing the cdev backend with real GPIO interrupts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up GPIO Simulator for circuits_gpio tests${NC}"

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   echo -e "${RED}Error: This script should not be run as root!${NC}"
   echo "The script will use sudo when needed for specific commands."
   exit 1
fi

# Check if gpio-sim kernel module is available
if ! modinfo gpio-sim &>/dev/null; then
    echo -e "${RED}Error: gpio-sim kernel module not found${NC}"
    echo "Make sure you have a kernel with CONFIG_GPIO_SIM enabled (Linux 5.17+)"
    echo "On Ubuntu/Debian, try: sudo apt install linux-modules-extra-\$(uname -r)"
    exit 1
fi

# Check if libgpiod tools are available
if ! command -v gpioinfo &>/dev/null; then
    echo -e "${RED}Error: libgpiod tools not found${NC}"
    echo "Install libgpiod tools: sudo apt install gpiod"
    exit 1
fi

# Check if configfs is mounted
if ! mountpoint -q /sys/kernel/config; then
    echo -e "${YELLOW}Mounting configfs...${NC}"
    sudo mount -t configfs none /sys/kernel/config
fi

# Load gpio-sim module if not already loaded
if ! lsmod | grep -q gpio_sim; then
    echo -e "${YELLOW}Loading gpio-sim module...${NC}"
    sudo modprobe gpio-sim
fi

# Define our GPIO simulator configuration
CHIP_NAME="gpiochip_sim"
CONFIG_PATH="/sys/kernel/config/gpio-sim/$CHIP_NAME"

# Remove existing configuration if it exists
if [[ -d "$CONFIG_PATH" ]]; then
    echo -e "${YELLOW}Removing existing gpio-sim configuration...${NC}"

    # First need to remove the device if it exists
    if [[ -f "$CONFIG_PATH/live" ]] && [[ $(cat "$CONFIG_PATH/live") == "1" ]]; then
        sudo sh -c "echo 0 > $CONFIG_PATH/live"
    fi

    # Remove banks (if any exist)
    for bank in "$CONFIG_PATH"/bank*; do
        if [[ -d "$bank" ]]; then
            for line in "$bank"/line*; do
                if [[ -d "$line" ]]; then
                    # Remove hogs if they exist
                    for hog in "$line"/hogs/hog*; do
                        if [[ -d "$hog" ]]; then
                            sudo rmdir "$hog"
                        fi
                    done
                    if [[ -d "$line/hogs" ]]; then
                        sudo rmdir "$line/hogs"
                    fi
                    sudo rmdir "$line"
                fi
            done
            sudo rmdir "$bank"
        fi
    done

    # Remove the chip configuration
    sudo rmdir "$CONFIG_PATH"
fi

# Install udev rule for gpio-sim permissions
echo -e "${YELLOW}Checking udev rule for gpio-sim permissions...${NC}"
UDEV_RULE="/etc/udev/rules.d/99-circuits-gpio-sim.rules"
if [[ ! -f "$UDEV_RULE" ]]; then
    sudo tee "$UDEV_RULE" > /dev/null <<'EOF'
# Rules for circuits_gpio testing

# Allow gpio group to access gpiochip devices
SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660", TAG+="uaccess"

# Allow gpio group to access pull and value attributes
ACTION=="add", SUBSYSTEM=="platform", DRIVERS=="gpio-sim", \
  RUN+="/bin/sh -c 'for d in /sys/devices/platform/%k/gpiochip*/sim_gpio*; do chgrp gpio \"$d/pull\" 2>/dev/null; chmod g+w \"$d/pull\" 2>/dev/null; done'"
EOF
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    echo -e "${GREEN}udev rule installed: $UDEV_RULE${NC}"
    echo "  Users in the 'gpio' group will have write access to /sys/devices/platform/gpio-sim/*"
else
    echo -e "${YELLOW}udev rule already exists: $UDEV_RULE${NC}"
fi

# Create new GPIO simulator configuration
echo -e "${YELLOW}Creating GPIO simulator configuration...${NC}"
sudo mkdir -p "$CONFIG_PATH"

# Create a bank with multiple GPIO lines
BANK_PATH="$CONFIG_PATH/bank0"
sudo mkdir -p "$BANK_PATH"

# Configure the bank with 8 GPIO lines (0-7)
sudo sh -c "echo 8 > $BANK_PATH/num_lines"

# Configure individual line properties
for i in {0..7}; do
    LINE_PATH="$BANK_PATH/line$i"
    sudo mkdir -p "$LINE_PATH"
    sudo sh -c "echo 'gpio_sim_line_$i' > $LINE_PATH/name"
done

# Activate the GPIO simulator
echo -e "${YELLOW}Activating GPIO simulator...${NC}"
sudo sh -c "echo 1 > $CONFIG_PATH/live"

echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "To run the GPIO simulator tests:"
echo "  mix test --include gpio_sim"
echo ""
echo "To clean up later:"
echo "  $0 cleanup"

# Handle cleanup if requested
if [[ "$1" == "cleanup" ]]; then
    echo -e "${YELLOW}Cleaning up GPIO simulator...${NC}"

    # Remove symbolic link
    if [[ -L "/dev/gpiochip_sim" ]]; then
        sudo rm "/dev/gpiochip_sim"
    fi

    # Deactivate and remove configuration
    if [[ -d "$CONFIG_PATH" ]]; then
        if [[ -f "$CONFIG_PATH/live" ]] && [[ $(cat "$CONFIG_PATH/live") == "1" ]]; then
            sudo sh -c "echo 0 > $CONFIG_PATH/live"
        fi

        # Remove banks
        for bank in "$CONFIG_PATH"/bank*; do
            if [[ -d "$bank" ]]; then
                # Remove line configurations
                for line in "$bank"/line*; do
                    if [[ -d "$line" ]]; then
                        # Remove hogs if they exist
                        for hog in "$line"/hogs/hog*; do
                            if [[ -d "$hog" ]]; then
                                sudo rmdir "$hog"
                            fi
                        done
                        if [[ -d "$line/hogs" ]]; then
                            sudo rmdir "$line/hogs"
                        fi
                        sudo rmdir "$line"
                    fi
                done
                sudo rmdir "$bank"
            fi
        done
        sudo rmdir "$CONFIG_PATH"
    fi

    echo -e "${GREEN}Cleanup complete!${NC}"
    exit 0
fi

# Show connection info for testing
echo -e "${YELLOW}Test configuration:${NC}"
echo "  GPIO lines 0-7 available for testing"
echo "  Test will verify:"
echo "    - Opening GPIO pins with cdev backend"
echo "    - Setting up interrupts without errors"
echo "    - Basic read/write operations"
echo "    - Clean resource management"
echo ""
echo "  For manual interrupt testing, you can use:"
echo "    gpioset gpiochip_sim 1=1  # Set line 1 high"
echo "    gpioset gpiochip_sim 1=0  # Set line 1 low"
