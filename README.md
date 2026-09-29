sim1802
=======

Simulator for the [RCA CDP1802](https://en.wikipedia.org/wiki/RCA_1802) processor

Build
-----

    $ make
    $ make PREFIX=${PREFIX} install

This installs the simulator as `cdp1802-unknown-elf-sim` in `${PREFIX}/bin/`,
a DejaGnu board definition `cdp1802-sim.exp` in `${PREFIX}/dejagnu/`, and
updates `${HOME}/.dejagnurc` to make that directory searchable by DejaGnu.

Usage
-----

This simulator runs ELF executables produced by the CDP1802 toolchain
(ports of GNU binutils and GCC, custom libc):

    $ echo 'extern int puts(const char *); int main(void) { puts("hello"); return 0; }' > hello.c
    $ cdp1802-unknown-elf-gcc -O hello.c
    $ cdp1802-unknown-elf-sim a.out
    hello

To use this simulator to run the test suite for `cdp1802-unknown-elf-gcc`,
append `RUNTESTFLAGS=--target_board=cdp1802-sim` to the `make check` command.

Use with Intel HEX files
------------------------

    $ a18 priv/hello.asm -l hello.lst -o hello.hex
    ...
    No Errors
    $ bin/sim1802 hello.hex
    HELO

For this use case you need a CDP1802 cross-assembler capable of emitting Intel
HEX files. I use [a18](https://github.com/mikpe/A18).

cdp1802-nuttx fork additions
----------------------------

This branch (`cdp1802-nuttx`) extends the simulator for an RTOS port
(Apache NuttX). All additions are backwards compatible: programs that
don't use them behave as before.

ROM mode (boot exactly like a real board):

    cdp1802-unknown-elf-objcopy -O binary nuttx.elf nuttx.bin   # the EPROM contents
    sim1802 --rom nuttx.bin [--rom-size N] [--ram-seed N]
            [--rom-writes ignore|warn|trap] [--symbols nuttx.elf]

The raw binary is mapped at 0x0000 and the CPU starts from the reset state
(RCA MPM-201A p. 72: X=P=0, R0=0, Q=0, IE=1), with nothing else prepared:

- the rest of the ROM window (`--rom-size`, default 32768) reads 0xFF, like an
  erased EPROM; RAM is everything above it;
- RAM and the registers that reset leaves undefined (R1..R15, D, DF, T) hold
  pseudo-random values from `--ram-seed` (default 1802): a run is
  reproducible, but code that assumes zeroed RAM or registers breaks as on
  hardware;
- no bootstrap code and no boot arguments are written;
- writes to ROM are ignored like on hardware (`--rom-writes warn` reports
  them, `trap` stops with exit status 97);
- `--symbols` reads only the symbol names of an ELF file, for `-t`/`-d`.

Bank-switched ROM (`--banks N [--bank-port P]`, ROM mode only, `--rom-size`
at most 32768): 0x8000-0xBFFF is a window onto one of N 16 KiB ROM banks.
The image file is the fixed ROM (padded to `--rom-size`) followed by bank 0,
bank 1, ...; missing banks read 0xFF.  `OUT P` (default 1) writes an 8-bit
latch that selects the bank; a value >= N leaves the window reading 0xFF.
The latch powers up with a pseudo-random value, like a real latch, so
start-up code must select a bank before using one.  The window is
write-protected like the rest of the ROM, and RAM starts at 0xC000.
This is the memory map of the NuttX port's HWB profile (a latch whose
outputs drive the high address lines of a large EPROM).  In an instruction
trace (`-t`), addresses in the window are followed by ` [bN]`, the selected
bank, because the symbol names there are ambiguous.

The console is 8-bit clean in all modes (bytes 0x80-0xFF pass unchanged).

`--dump FILE` writes the 64 KiB address space, as the CPU sees it (the bank
window shows the selected bank), to FILE when the simulator stops for any
reason, and prints the registers: a post-mortem for hung or crashed
programs (e.g. walking an RTOS's task list with the program's symbols).

Command-line options:

    --cycles          print "@ cycles N" (machine cycles) on stderr at exit
    --max-cycles N    stop after N machine cycles with exit status 96
    --pace HZ         when idling on the cycle timer, wait the host time that
                      the idle period takes on a CPU clocked at HZ (a machine
                      cycle is 8 clock periods); for interactive use

Machine cycles: every instruction adds its documented cycle count (2, or 3
for long branch, long skip and NOP, per RCA MPM-201A; CDP1805AC/1806AC
datasheet values for 68-prefixed instructions), and an interrupt response
adds 1.

I/O commands (`OUT 7`; arguments and results via `OUT 6`/`INP 6`):

| Command | Name | Effect |
|---------|------|--------|
| `0x80` | TIMER_WRITE_CONTROL | modes 0-3 unchanged; **4** = IRQ 0 every *period* machine cycles (deterministic) |
| `0x81`-`0x83` | TIMER_WRITE_PERIOD0..2 | bits 0-7, 8-15, 16-23 of the period |
| `0x84` | CYCLES_LATCH | latch the machine-cycle counter |
| `0x85`-`0x88` | CYCLES_READ0..3 | byte 0 (LSB) .. 3 of the latched count (mod 2^32) |
| `0xE1` | CONSOLE_GETCHAR | next byte of host stdin (0 if none) |
| `0xE2` | CONSOLE_STATUS | bit 0: input available; bit 1: end of input |

In timer mode 4, `IDL` advances simulated time to the next timer interrupt,
so idle time costs no host time and results do not depend on host speed.

IRQ 6 (console) is level-triggered: it is pending exactly while input is
queued, and it is raised once at end of input. Drain the input before
re-enabling IRQ 6. Host stdin is only read once a program uses console
input (0xE1/0xE2 or enabling IRQ 6).

ELF segments are loaded at their physical (load) address `p_paddr`, which
equals `p_vaddr` for ordinary images; a ROM image whose `.data` is copied to
RAM at start-up gets its initial `.data` into ROM, as on real hardware.

ROM emulation: if the ELF image defines the symbol `__sim1802_rom_end`,
writes to `[0, __sim1802_rom_end)` trap ("write to write-protected
address", exit status 97). Without it, the upstream rule (`__DTOR_END__` or
`_fini`) applies.

Pending-interrupt bits are now updated atomically, fixing a possible lost
update between the timer process and interrupt acknowledgement.

Dependencies
------------

The simulator is written in Erlang so you need that to build and run it.
