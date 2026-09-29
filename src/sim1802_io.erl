%%% -*- erlang-indent-level: 2 -*-
%%%
%%% I/O for CDP1802 simulator
%%%
%%% The I/O device consists of:
%%%
%%% - an 8-bit argument/result buffer
%%% - an interrupt controller for 8 IRQs 0..7:
%%%   * an 8-bit IRQ enabled register
%%%   * an 8-bit IRQ pending register
%%% - IRQ 0: timer
%%%   * a 2-bit control register
%%% - IRQs 1-5: reserved
%%% - IRQ 6: console
%%%   * an 8-bit input buffer
%%% - IRQ 7: reserved, could be used for daisy-chaining
%%%
%%% The argument/result buffer is written with OUT 6 and read with INP 6.
%%% Commands are written with OUT 7.
%%%
%%% Interrupts are handled as follows:
%%% 1. Device with IRQ I signals an interrupt request.
%%% 2. The interrupt controller sets bit 2^I in the pending register.
%%% 3. If any bit is set in the bitwise AND of the pending and enabled
%%%    registers, an interrupt request is signalled to the CPU.
%%% 4. The interrupt handler sends an INTERRUPT_ACKNOWLEDGE command.
%%% 5. The lowest set bit in the bitwise AND of the pending and enabled
%%%    registers is written to the result buffer, and cleared in the
%%%    pending and enable registers. If no bit is set, 8 is written to
%%%    the result buffer to signal a spurious interrupt. The interrupt
%%%    request to the CPU is cleared.
%%% 6. The interrupt handler reads the buffer and branches to the
%%%    device-specific handler.
%%% 7. Interrupts from the device may be re-enabled by setting its
%%%    bit in the interrupt enable register.

-module(sim1802_io).

-export([ init/0
        , inp/1
        , is_interrupt/0
        , out/3
        , wait_interrupt/0
        ]).

%% private: enable reloading code
-export([ semaphore_loop/1
        , timer_disabled_loop/0
        , timer_enabled_loop/1
        ]).

-export_type([ portnr/0
             ]).

-type portnr() :: 1..7.

-include("sim1802_io.hrl").

-define(ETS, ?MODULE).

%% API =========================================================================

-spec init() -> ok.
init() ->
  ets:new(?ETS, [named_table, public]),
  buffer_init(),
  semaphore_init(),
  interrupt_init(),
  timer_init(),
  ok.

-spec inp(portnr()) -> byte().
inp(PortNr) ->
  case PortNr of
    ?SIM1802_IO_BUF -> read_buffer();
    _ -> 0
  end.

-spec out(sim1802_core:core(), portnr(), byte()) -> ok.
out(Core, PortNr, Byte) ->
  case PortNr of
    ?SIM1802_IO_BUF -> write_buffer(Byte);
    ?SIM1802_IO_CMD -> write_command(Core, Byte);
    _ -> ok
  end.

-spec is_interrupt() -> boolean().
is_interrupt() ->
  read_semaphore().

-spec wait_interrupt() -> ok.
wait_interrupt() ->
  wait_semaphore().

%% Internal ====================================================================

-define(buffer, buffer).

buffer_init() ->
  ets:insert(?ETS, {?buffer, 0}),
  ok.

read_buffer() ->
  ets:lookup_element(?ETS, ?buffer, 2).

write_buffer(Byte) ->
  ets:update_element(?ETS, ?buffer, {2, Byte}),
  ok.

write_command(Core, Command) ->
  case Command of
    ?SIM1802_CMD_HALT ->
      sim1802_core:halt(Core, read_buffer());
    ?SIM1802_CMD_INTERRUPT_ACKNOWLEDGE ->
      interrupt_acknowledge();
    ?SIM1802_CMD_INTERRUPT_READ_ENABLED ->
      interrupt_read_enabled();
    ?SIM1802_CMD_INTERRUPT_READ_PENDING ->
      interrupt_read_pending();
    ?SIM1802_CMD_INTERRUPT_WRITE_ENABLED ->
      interrupt_write_enabled();
    ?SIM1802_CMD_INTERRUPT_WRITE_PENDING ->
      interrupt_write_pending();
    ?SIM1802_CMD_TIMER_WRITE_CONTROL ->
      timer_write_control();
    ?SIM1802_CMD_CONSOLE_PUTCHAR ->
      console_putchar();
    _ ->
      io:format(standard_error, "@ Invalid I/O command 0x~2.16.0B\n", [Command])
  end.

%% Semaphore =================================================================

-define(SEMAPHORE, sim1802_semaphore).
-define(semaphore, semaphore).

semaphore_init() ->
  spawn_link(
    fun() ->
      register(?SEMAPHORE, self()),
      ?MODULE:semaphore_loop(false)
    end),
  ets:insert(?ETS, {?semaphore, false}).

read_semaphore() ->
  ets:lookup_element(?ETS, ?semaphore, 2).

write_semaphore(Flag) ->
  ets:update_element(?ETS, ?semaphore, {2, Flag}).

reset_semaphore() ->
  write_semaphore(false).

set_semaphore() ->
  call(set).

wait_semaphore() ->
  call(wait).

semaphore_loop(Waiter) ->
  receive
    {wait, Pid, Ref} when Waiter =:= false ->
      case read_semaphore() of
        true ->
          reply_ok(Pid, Ref),
          ?MODULE:semaphore_loop(false);
        false ->
          ?MODULE:semaphore_loop({Pid, Ref})
      end;
    {set, Pid, Ref} ->
      write_semaphore(true),
      release_waiter(Waiter),
      reply_ok(Pid, Ref),
      ?MODULE:semaphore_loop(false);
    Msg ->
      io:format(standard_error, "@ Invalid semaphore msg ~p (waiter ~p)\n", [Msg, Waiter]),
      ?MODULE:semaphore_loop(Waiter)
  after 60_000 ->
    ?MODULE:semaphore_loop(Waiter)
  end.

release_waiter(false) -> ok;
release_waiter({Pid, Ref}) -> reply_ok(Pid, Ref).

call(Tag) ->
  Pid = whereis(?SEMAPHORE),
  Ref = make_ref(),
  Pid ! {Tag, self(), Ref},
  receive {ok, Pid, Ref} -> ok end.

reply_ok(Pid, Ref) -> Pid ! {ok, self(), Ref}.

%% Interrupt Controller ======================================================

-define(enabled, enabled).
-define(pending, pending).
-define(IRQ_SPURIOUS, 8).

interrupt_init() ->
  ets:insert(?ETS, {?enabled, 0}),
  %% One tuple element per IRQ: {pending, P0, ..., P7}.  The timer process
  %% and the CPU both change pending bits; updating one
  %% element with ets:update_element/3 is atomic, so no update is lost
  %% (a read-modify-write of a single byte could lose one).
  ets:insert(?ETS, {?pending, 0, 0, 0, 0, 0, 0, 0, 0}),
  ok.

interrupt_acknowledge() ->
  Enabled = read_enabled(),
  Pending = read_pending(),
  case Enabled band Pending of
    0 ->
      write_buffer(?IRQ_SPURIOUS);
    Mask ->
      IRQ = ctz(Mask),
      write_enabled(Enabled band bnot (1 bsl IRQ)),
      clear_pending(IRQ),
      write_buffer(IRQ),
      reset_semaphore(),
      check_interrupt()
  end.

%% ctz - count trailing zeros
-spec ctz(non_neg_integer()) -> pos_integer().
ctz(NonZero) ->
  %% Width should be larger in general, this value is optimized for byte-sized inputs.
  ctz(NonZero, _Width = 4, _CTZ = 0).

ctz(_NonZero = 1, _Width, CTZ) -> CTZ;
ctz(NonZero, Width, CTZ) ->
  case NonZero band ((1 bsl Width) - 1) of
    0 -> ctz(NonZero bsr Width, Width, CTZ + Width);
    NonZero2 -> ctz(NonZero2, Width div 2, CTZ)
  end.

interrupt_read_enabled() ->
  write_buffer(read_enabled()).

interrupt_read_pending() ->
  write_buffer(read_pending()).

interrupt_write_enabled() ->
  write_enabled(read_buffer()),
  check_interrupt().

interrupt_write_pending() ->
  write_pending(read_buffer()),
  check_interrupt().

set_interrupt(IRQ) ->
  ets:update_element(?ETS, ?pending, {IRQ + 2, 1}),
  check_interrupt().

clear_pending(IRQ) ->
  ets:update_element(?ETS, ?pending, {IRQ + 2, 0}).

check_interrupt() ->
  case read_enabled() band read_pending() of
    0 -> ok;
    _ -> set_semaphore()
  end.

read_enabled() ->
  ets:lookup_element(?ETS, ?enabled, 2).

read_pending() ->
  [{?pending, P0, P1, P2, P3, P4, P5, P6, P7}] = ets:lookup(?ETS, ?pending),
  P0 bor (P1 bsl 1) bor (P2 bsl 2) bor (P3 bsl 3)
    bor (P4 bsl 4) bor (P5 bsl 5) bor (P6 bsl 6) bor (P7 bsl 7).

write_enabled(Byte) ->
  ets:update_element(?ETS, ?enabled, {2, Byte}),
  ok.

write_pending(Byte) ->
  ets:update_element(?ETS, ?pending,
                     [{I + 2, (Byte bsr I) band 1} || I <- lists:seq(0, 7)]),
  ok.

%% Timer =====================================================================

-define(IRQ_TIMER, 0).
-define(TIMER, sim1802_timer).

timer_init() ->
  spawn_link(
    fun() ->
      register(?TIMER, self()),
      ?MODULE:timer_disabled_loop()
    end).

timer_disabled_loop() ->
  receive
    {reset, Mode} -> timer_reset(Mode)
  after 60_000 ->
    ?MODULE:timer_disabled_loop()
  end.

timer_enabled_loop(DelayMs) ->
  receive
    {reset, Mode} -> timer_reset(Mode)
  after DelayMs ->
    set_interrupt(?IRQ_TIMER),
    ?MODULE:timer_enabled_loop(DelayMs)
  end.

timer_reset(Mode) ->
  case timer_delay(Mode) of
    infinity -> ?MODULE:timer_disabled_loop();
    DelayMs -> timer_enabled_loop(DelayMs)
  end.

timer_delay(Mode) ->
  case Mode of
    0 -> infinity; % disabled
    1 -> 10_000;   % 0.1Hz
    2 ->  1_000;   % 1Hz
    3 ->    100;   % 10Hz
    _ ->
      io:format(standard_error, "@ Invalid timer mode ~p\n", [Mode]),
      infinity
  end.

timer_write_control() ->
  Byte = read_buffer(),
  ?TIMER ! {reset, Byte},
  ok.

%% Console =====================================================================

console_putchar() ->
  file:write(standard_io, [read_buffer()]),
  ok.
