# Operating System Kernel

An Operating System kernel written for academic purposes.

## Development

### Set-up

1. Install QEMU for your development system.
2. Install the Zig toolchain and add it to your path.
3. Install VSCode.
4. Install all recommended VSCode extensions when prompted.

### Debugging

Do the following:

1. Run one of the "Debug" launch presets in VSCode.
2. Open command palette &rarr; Tasks: Run Task &rarr; launch QEMU.

Note: The kernel is currently always loaded at the same address. If/when this
no longer becomes the case, the `.text` address will have to be specified
manually.
