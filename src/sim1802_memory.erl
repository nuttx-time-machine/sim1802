%%% -*- erlang-indent-level: 2 -*-
%%%
%%% CDP1802 memory simulation
%%%
%%% - 64KB RAM initialized to all bits zero, stored in an atomics array
%%% - an initial portion of the RAM can be marked as write-protected
%%% - cdp1802-nuttx fork: a write to protected memory either traps (default,
%%%   ELF images), prints a warning and is dropped, or is silently dropped
%%%   like on a real ROM (--rom mode)
%%% - cdp1802-nuttx fork, --rom mode with --banks N: a bank-switched ROM
%%%   window at 0x8000-0xBFFF.  An 8-bit write-only latch on an output port
%%%   selects which 16 KiB bank of the ROM appears in the window; a latch
%%%   value >= N selects nothing and the window reads 0xFF.  Like the rest of
%%%   the ROM, the window is write-protected.

-module(sim1802_memory).

-export([ init/0
        , get_byte/1
        , set_byte/2
        , write_protect/1
        , write_protect/2
        , write_protect_mode/0
        , is_write_protected/1
        , init_banks/3
        , bank_out/2
        , bank_select/0
        ]).

-export_type([ wp_mode/0
             ]).

-type wp_mode() :: trap | warn | ignore.

-export_type([ address/0
             ]).

-define(UINT16_MAX, ((1 bsl 16) - 1)).
-type address() :: 0..?UINT16_MAX.

%% persistent_term keys
-define(ATOMICS, ?MODULE).
-define(WP, sim1802_memory_write_protect).
-define(WP_MODE, sim1802_memory_write_protect_mode).
-define(BANKS, sim1802_memory_banks). % {BankAtomics, LatchAtomics, NumBanks, Port}

-define(BANK_BASE, 16#8000).
-define(BANK_SIZE, 16#4000).

%% API =========================================================================

-spec init() -> ok.
init() ->
  A = atomics:new(65536, []),
  persistent_term:put(?ATOMICS, A),
  ok.

-spec get_byte(address()) -> byte().
get_byte(Address) when Address >= ?BANK_BASE, Address < ?BANK_BASE + ?BANK_SIZE ->
  case persistent_term:get(?BANKS, none) of
    none ->
      atomics:get(persistent_term:get(?ATOMICS), Address + 1);
    {BA, Latch, N, _Port} ->
      case atomics:get(Latch, 1) of
        Bank when Bank < N -> atomics:get(BA, Bank * ?BANK_SIZE + (Address - ?BANK_BASE) + 1);
        _ -> 16#FF
      end
  end;
get_byte(Address) ->
  A = persistent_term:get(?ATOMICS),
  atomics:get(A, Address + 1).

-spec set_byte(address(), byte()) -> ok.
set_byte(Address, Byte) ->
  A = persistent_term:get(?ATOMICS),
  atomics:put(A, Address + 1, Byte).

-spec write_protect(address()) -> ok.
write_protect(Limit) ->
  persistent_term:put(?WP, Limit).

-spec write_protect(address(), wp_mode()) -> ok.
write_protect(Limit, Mode) ->
  persistent_term:put(?WP_MODE, Mode),
  write_protect(Limit).

-spec write_protect_mode() -> wp_mode().
write_protect_mode() ->
  persistent_term:get(?WP_MODE, trap).

-spec is_write_protected(address()) -> boolean().
is_write_protected(Address) when Address >= ?BANK_BASE, Address < ?BANK_BASE + ?BANK_SIZE ->
  persistent_term:get(?BANKS, none) =/= none
    orelse Address < persistent_term:get(?WP, 0);
is_write_protected(Address) ->
  Limit = persistent_term:get(?WP, 0),
  Address < Limit.

%% Bank-switched ROM window (--rom mode only).  Bin holds the banks back to
%% back (bank 0 first); the part not covered by Bin reads 0xFF.  The latch
%% powers up with InitialLatch (a random value in --rom mode).
-spec init_banks({pos_integer(), 1..7}, binary(), byte()) -> ok.
init_banks({NumBanks, Port}, Bin, InitialLatch) ->
  BA = atomics:new(NumBanks * ?BANK_SIZE, []),
  fill_banks(BA, 1, NumBanks * ?BANK_SIZE, Bin),
  Latch = atomics:new(1, []),
  atomics:put(Latch, 1, InitialLatch),
  persistent_term:put(?BANKS, {BA, Latch, NumBanks, Port}),
  ok.

%% OUT to a port that is not the I/O controller's: the bank latch if it is
%% on that port, otherwise nothing is connected.
-spec bank_out(1..7, byte()) -> ok.
bank_out(Port, Byte) ->
  case persistent_term:get(?BANKS, none) of
    {_BA, Latch, _N, Port} -> atomics:put(Latch, 1, Byte);
    _ -> ok
  end.

%% Current latch value (for traces), or none without a bank window.
-spec bank_select() -> byte() | none.
bank_select() ->
  case persistent_term:get(?BANKS, none) of
    {_BA, Latch, _N, _Port} -> atomics:get(Latch, 1);
    none -> none
  end.

fill_banks(_BA, I, Size, _Bin) when I > Size -> ok;
fill_banks(BA, I, Size, <<Byte, Rest/binary>>) ->
  atomics:put(BA, I, Byte),
  fill_banks(BA, I + 1, Size, Rest);
fill_banks(BA, I, Size, <<>>) ->
  atomics:put(BA, I, 16#FF),
  fill_banks(BA, I + 1, Size, <<>>).

%% Tests =======================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

banks_test() ->
  ok = init(),
  set_byte(16#7FFF, 16#11),
  set_byte(16#C000, 16#22),
  %% two banks: bank 0 starts with 0xA0, bank 1 with 0xB1; latch on port 1
  Bin = <<16#A0, 0:(16#4000 - 1)/unit:8, 16#B1>>,
  ok = init_banks({2, 1}, Bin, 0),
  ?assertEqual(16#A0, get_byte(16#8000)),
  ok = bank_out(1, 1),
  ?assertEqual(16#B1, get_byte(16#8000)),
  ?assertEqual(16#FF, get_byte(16#8001)),        % rest of bank 1: erased
  ok = bank_out(2, 0),                           % another port: ignored
  ?assertEqual(16#B1, get_byte(16#8000)),
  ok = bank_out(1, 7),                           % no such bank
  ?assertEqual(16#FF, get_byte(16#8000)),
  ?assert(is_write_protected(16#BFFF)),
  ?assertEqual(16#11, get_byte(16#7FFF)),        % outside the window
  ?assertEqual(16#22, get_byte(16#C000)),
  persistent_term:erase(?BANKS).

-endif.
