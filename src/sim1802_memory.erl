%%% -*- erlang-indent-level: 2 -*-
%%%
%%% CDP1802 memory simulation
%%%
%%% - 64KB RAM initialized to all bits zero, stored in an atomics array
%%% - an initial portion of the RAM can be marked as write-protected
%%% - cdp1802-nuttx fork: a write to protected memory either traps (default,
%%%   ELF images), prints a warning and is dropped, or is silently dropped
%%%   like on a real ROM (--rom mode)

-module(sim1802_memory).

-export([ init/0
        , get_byte/1
        , set_byte/2
        , write_protect/1
        , write_protect/2
        , write_protect_mode/0
        , is_write_protected/1
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

%% API =========================================================================

-spec init() -> ok.
init() ->
  A = atomics:new(65536, []),
  persistent_term:put(?ATOMICS, A),
  ok.

-spec get_byte(address()) -> byte().
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
is_write_protected(Address) ->
  Limit = persistent_term:get(?WP, 0),
  Address < Limit.
