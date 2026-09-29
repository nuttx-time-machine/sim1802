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

Pending-interrupt bits are now updated atomically, fixing a possible lost
update between the timer process and interrupt acknowledgement.

Dependencies
------------

The simulator is written in Erlang so you need that to build and run it.
