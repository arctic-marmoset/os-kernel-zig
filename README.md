# Operating System Kernel

An Operating System kernel written for academic purposes.

## Development

### Set-up

1. Install QEMU for your development system.
2. Install the Zig toolchain and add it to your path.
3. Install VSCode.
4. Install all recommended VSCode extensions when prompted.

### Debugging

Do the following in any order:

- Run one of the "Debug" launch presets in VSCode.
- Open command palette &rarr; Tasks: Run Task &rarr; launch QEMU.

#### Loading Debug Symbols for the Bootloader

1. Break in with LLDB.
2. In VSCode's "Debug Console", enter the command `uefi load-symbols`.
3. Step over.

Note: Since the bootloader is written for UEFI, it follows the MSVC ABI, and
therefore produces debug symbols in PDB format. However, as of LLVM 15, LLDB
will often crash when stepping through code if symbols are loaded from PDB
files.

#### Loading Debug Symbols for the Kernel

1. Break in with LLDB.
2. In VSCode's "Debug Console", enter the following commands:
```
image add zig-out/hdd/kernel.elf
image load --file path/to/kernel.elf --slide 0
```
3. Step over.

Note: The kernel is currently always loaded at the same address. If/when this
no longer becomes the case, the `.text` address will have to be specified
manually.
