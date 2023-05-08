# Adapted for LLDB from https://github.com/x1tan/rust-uefi-runtime-driver.

try:
    import lldb
except:
    pass

import os

CONTAINER = "uefi"


def __lldb_init_module(debugger: lldb.SBDebugger, internal_dict: dict):
    debugger.HandleCommand(f"command container add {CONTAINER}")
    debugger.HandleCommand(f"command script add -f uefi.load_symbols {CONTAINER} load-symbols")
    print("UEFI utility commands loaded")


def load_symbols(
    debugger: lldb.SBDebugger,
    command: str,
    exe_ctx: lldb.SBExecutionContext,
    result: lldb.SBCommandReturnObject,
    internal_dict: dict,
):
    ARGC_MIN = 1

    argv = command.split()
    argc = len(argv)
    if argc < ARGC_MIN:
        result.SetError(f"expected minimum argument count of {ARGC_MIN}, got {argc}")
        return

    BINARY_NAME = "bootx64"
    BINARY_NAME_WITH_EXT = f"{BINARY_NAME}.efi"

    address_str = argv[0]
    wait_variable_name = argv[1] if argc > 1 else "waiting"
    binary_path = argv[2] if argc > 2 else f"zig-out/hdd/EFI/BOOT/{BINARY_NAME_WITH_EXT}"
    symbols_path = argv[3] if argc > 3 else f"zig-out/hdd/EFI/BOOT/{BINARY_NAME}.pdb"

    binary_name_with_ext = os.path.basename(binary_path)

    if address_str[0] == "$":
        register_name = address_str[1:]
        register = exe_ctx.frame.FindRegister(register_name)
        if not register:
            result.SetError(f"invalid register '{register_name}'")
            return
        address = register.unsigned
    elif address_str.startswith("0x"):
        try:
            address = int(address_str, base=16)
        except ValueError:
            result.SetError(f"invalid hexadecimal literal '{address_str}'")
            return
    else:
        try:
            address = int(address_str)
        except ValueError:
            result.SetError(f"expected an address or register, got '{address_str}'")
            return

    print(f"reference address: 0x{address:08x}")
    print(f"binary path: {binary_path}")
    print(f"symbols path: {symbols_path}")

    PE_MAGIC = 0x785A4D

    error = lldb.SBError()
    base_address = address & 0xFFFFF000
    while exe_ctx.process.ReadUnsignedFromMemory(base_address, 4, error) != PE_MAGIC:
        if error.Fail():
            result.SetError(error)
            return
        base_address -= 0x1000

    print(f'base address: 0x{base_address:08x}')
    debugger.HandleCommand(f"target symbols add {symbols_path}")
    debugger.HandleCommand(f"target modules load --file {binary_name_with_ext} --slide {base_address}")
    debugger.HandleCommand(f"expr {wait_variable_name} = 0")
