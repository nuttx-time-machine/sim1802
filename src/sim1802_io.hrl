%%% -*- erlang-indent-level: 2 -*-
%%%
%%% I/O for CDP1802 simulator

-ifndef(SIM1802_IO_HRL).
-define(SIM1802_IO_HRL, 1).

%% Port numbers to use with INP/OUT
-define(SIM1802_IO_BUF, 6). % buffer (read/write)
-define(SIM1802_IO_CMD, 7). % command (write-only)

%% Miscellaneous commands:
-define(SIM1802_CMD_HALT,                       16#00).

%% Interrupt controller commands:
-define(SIM1802_CMD_INTERRUPT_ACKNOWLEDGE,      16#10).
-define(SIM1802_CMD_INTERRUPT_READ_ENABLED,     16#11).
-define(SIM1802_CMD_INTERRUPT_READ_PENDING,     16#12).
-define(SIM1802_CMD_INTERRUPT_WRITE_ENABLED,    16#13).
-define(SIM1802_CMD_INTERRUPT_WRITE_PENDING,    16#14).

%% Timer commands:
-define(SIM1802_CMD_TIMER_WRITE_CONTROL,        16#80). % 0=Off, 1=0.1Hz, 2=1Hz, 3=10Hz, 4=cycles
%% cdp1802-nuttx fork: deterministic timer driven by machine cycles.
%% Write the 24-bit period (in machine cycles) byte by byte, then select
%% timer mode 4 with TIMER_WRITE_CONTROL.  IRQ 0 is raised every period.
-define(SIM1802_CMD_TIMER_WRITE_PERIOD0,        16#81). % period bits 0..7
-define(SIM1802_CMD_TIMER_WRITE_PERIOD1,        16#82). % period bits 8..15
-define(SIM1802_CMD_TIMER_WRITE_PERIOD2,        16#83). % period bits 16..23
%% cdp1802-nuttx fork: machine-cycle counter.  LATCH captures the current
%% count; READ0..READ3 put bytes 0 (least significant) .. 3 of the latched
%% value (modulo 2^32) in the buffer.
-define(SIM1802_CMD_CYCLES_LATCH,               16#84).
-define(SIM1802_CMD_CYCLES_READ0,               16#85).
-define(SIM1802_CMD_CYCLES_READ1,               16#86).
-define(SIM1802_CMD_CYCLES_READ2,               16#87).
-define(SIM1802_CMD_CYCLES_READ3,               16#88).

%% Console commands:
-define(SIM1802_CMD_CONSOLE_PUTCHAR,            16#E0).
-define(SIM1802_CMD_CONSOLE_GETCHAR,            16#E1). % buffer := next input byte (0 if none)
%% cdp1802-nuttx fork: console input status.  Buffer bit 0: an input byte is
%% available; bit 1: end of input (host stdin closed) and nothing buffered.
-define(SIM1802_CMD_CONSOLE_STATUS,             16#E2).

-endif. % SIM1802_IO_HRL
