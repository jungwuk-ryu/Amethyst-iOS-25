"""LLDB host for Amethyst's iOS 26+ Universal JIT protocol.

Usage after launching the app with devicectl --start-stopped:

    (lldb) device select <device>
    (lldb) device process attach -p <pid>
    (lldb) command script import scripts/lldb_jit26.py
    (lldb) process handle SIGBUS  -s false -n false -p true
    (lldb) process handle SIGSEGV -s false -n false -p true
    (lldb) process handle SIGFPE  -s false -n false -p true
    (lldb) process handle SIGILL  -s false -n false -p true
    (lldb) process handle SIGTRAP -s true  -n true  -p false
    (lldb) process continue

After each Universal JIT SIGTRAP:

    (lldb) amethyst-jit26-handle-stop
    (lldb) process continue

Repeat those two commands until the handler reports that it prepared the JIT
mapping and detached. Handling one stop per command deliberately avoids calling
the synchronous process-control API from inside an LLDB Python callback, which
can deadlock LLDB's event thread.

HotSpot deliberately installs handlers for these four signals. LLDB must pass
them through without stopping; otherwise a normal JVM signal probe is mistaken
for an event outside the Universal JIT protocol.

This is intended for development-device testing from a Mac. StikDebug remains
the normal on-device host for the bundled UniversalJIT26.js script.
"""

import struct

import lldb


JIT_PAGE_SIZE = 0x4000
BRK_MASK = 0xFFE0001F
BRK_OPCODE = 0xD4200000
LEGACY_SCRIPT_SENTINEL = 0x690000E0
_HOSTS = {}


class UniversalJIT26Host:
    def __init__(self, process):
        self.process = process
        self.extension_installed = False
        self.detach_after_first_mapping = False
        self.should_detach = False

    @staticmethod
    def _register(frame, name):
        register = frame.FindRegister(name)
        if not register.IsValid():
            raise RuntimeError(f"register {name} is unavailable")
        return register

    @classmethod
    def _read_register(cls, frame, name):
        return cls._register(frame, name).GetValueAsUnsigned()

    @classmethod
    def _write_register(cls, frame, name, value):
        register = cls._register(frame, name)
        if not register.SetValueFromCString(f"0x{value:x}"):
            raise RuntimeError(f"failed to write register {name}")

    def _read_memory(self, address, size):
        error = lldb.SBError()
        data = self.process.ReadMemory(address, size, error)
        if error.Fail() or len(data) != size:
            raise RuntimeError(
                f"failed to read {size} bytes at 0x{address:x}: {error}"
            )
        return data

    def _write_memory(self, address, data):
        error = lldb.SBError()
        written = self.process.WriteMemory(address, data, error)
        if error.Fail() or written != len(data):
            raise RuntimeError(
                f"failed to write {len(data)} bytes at 0x{address:x}: {error}"
            )

    def _allocate_rx(self, size):
        error = lldb.SBError()
        permissions = lldb.ePermissionsReadable | lldb.ePermissionsExecutable
        address = self.process.AllocateMemory(size, permissions, error)
        if error.Fail() or address == lldb.LLDB_INVALID_ADDRESS:
            raise RuntimeError(f"failed to allocate {size} RX bytes: {error}")
        return address

    def _prepare_new_mapping(self, address, size):
        # A debugger write to every 16 KiB executable page opts that page into
        # Apple's debug-backed JIT mapping on TXM devices.
        for offset in range(0, size, JIT_PAGE_SIZE):
            self._write_memory(address + offset, b"\x69")

    def _rewrite_existing_mapping(self, address, size):
        # Preserve existing instructions while making the writes originate
        # from debugserver, matching UniversalJIT26Extension.js command 4.
        for offset in range(0, size, JIT_PAGE_SIZE):
            chunk_size = min(JIT_PAGE_SIZE, size - offset)
            chunk = self._read_memory(address + offset, chunk_size)
            self._write_memory(address + offset, chunk)

    def _selected_stop_frame(self):
        thread = self.process.GetSelectedThread()
        if not thread.IsValid() or thread.GetStopReason() == lldb.eStopReasonNone:
            for candidate in self.process:
                if candidate.GetStopReason() != lldb.eStopReasonNone:
                    thread = candidate
                    break
        if not thread.IsValid():
            raise RuntimeError("no stopped thread is available")
        frame = thread.GetFrameAtIndex(0)
        if not frame.IsValid():
            raise RuntimeError("no stopped frame is available")
        return frame

    def handle_stop(self):
        frame = self._selected_stop_frame()
        pc = frame.GetPC()
        instruction = struct.unpack("<I", self._read_memory(pc, 4))[0]
        if instruction & BRK_MASK != BRK_OPCODE:
            return False

        immediate = (instruction >> 5) & 0xFFFF
        x0 = self._read_register(frame, "x0")
        x1 = self._read_register(frame, "x1")
        x16 = self._read_register(frame, "x16")

        if immediate == 0x69:
            if not self.extension_installed:
                self._write_register(frame, "x0", LEGACY_SCRIPT_SENTINEL)
                print("[jit26-lldb] Universal script handshake", flush=True)
            else:
                mapping_size = x0
                if mapping_size == 0:
                    raise RuntimeError("JIT mapping request has zero size")
                mapping = self._allocate_rx(mapping_size)
                self._prepare_new_mapping(mapping, mapping_size)
                self._write_register(frame, "x0", mapping)
                self.should_detach = self.detach_after_first_mapping
                print(
                    f"[jit26-lldb] prepared RX mapping "
                    f"0x{mapping:x} ({mapping_size} bytes)",
                    flush=True,
                )
        elif immediate == 0xF00D:
            if x16 == 1:
                mapping = x0
                if mapping == 0:
                    mapping = self._allocate_rx(x1)
                self._prepare_new_mapping(mapping, x1)
                self._write_register(frame, "x0", mapping)
                print(
                    f"[jit26-lldb] prepared region "
                    f"0x{mapping:x} ({x1} bytes)",
                    flush=True,
                )
            elif x16 == 2:
                self.extension_installed = True
                print("[jit26-lldb] Universal extension installed", flush=True)
            elif x16 == 3:
                self.detach_after_first_mapping = x0 != 0
                print(
                    "[jit26-lldb] detach-after-first-mapping = "
                    f"{self.detach_after_first_mapping}",
                    flush=True,
                )
            elif x16 == 4:
                self._rewrite_existing_mapping(x0, x1)
                print(
                    f"[jit26-lldb] rewrote executable region "
                    f"0x{x0:x} ({x1} bytes)",
                    flush=True,
                )
            elif x16 == 0:
                print("[jit26-lldb] detach request ignored for test run", flush=True)
            else:
                return False
        else:
            return False

        self._write_register(frame, "pc", pc + 4)
        return True


def amethyst_jit26_handle_stop(
    debugger, command, execution_context, result, _
):
    process = execution_context.GetProcess()
    if not process.IsValid():
        result.SetError("No valid process is selected.")
        return

    if process.GetState() != lldb.eStateStopped:
        result.SetError(
            "The process must be stopped at a Universal JIT SIGTRAP."
        )
        return

    process_id = process.GetProcessID()
    host = _HOSTS.get(process_id)
    if host is None:
        host = UniversalJIT26Host(process)
        _HOSTS[process_id] = host

    try:
        if not host.handle_stop():
            thread = process.GetSelectedThread()
            description = (
                thread.GetStopDescription(256)
                if thread.IsValid()
                else "unknown"
            )
            result.SetError(
                "Stopped for an event outside the Universal JIT protocol: "
                f"{description}"
            )
            return
    except Exception as error:
        result.SetError(f"Universal JIT handler failed: {error}")
        return

    if host.should_detach:
        error = process.Detach(False)
        if error.Fail():
            result.SetError(
                "Could not detach after preparing JIT mapping: "
                f"{error}"
            )
            return
        _HOSTS.pop(process_id, None)
        result.AppendMessage(
            "Prepared the JIT mapping and detached; "
            "the app is still running."
        )
        return

    result.AppendMessage(
        "Handled this Universal JIT stop. Run 'process continue'."
    )


def __lldb_init_module(debugger, _):
    debugger.HandleCommand(
        "command script add -f lldb_jit26.amethyst_jit26_handle_stop "
        "amethyst-jit26-handle-stop"
    )
    print(
        "[jit26-lldb] installed command: amethyst-jit26-handle-stop",
        flush=True,
    )
