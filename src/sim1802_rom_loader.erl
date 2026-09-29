%%% -*- erlang-indent-level: 2 -*-
%%%
%%% ROM-image loader for CDP1802 simulator (cdp1802-nuttx fork)
%%%
%%% Models a real board at power-on instead of a program loader:
%%% - the raw binary (the bytes you would program into the EPROM) is mapped
%%%   at address 0; the rest of the ROM window reads 0xFF (erased EPROM);
%%% - RAM above the ROM window holds undefined (pseudo-random) values, as
%%%   static RAM does after power-up, instead of zeros;
%%% - nothing else is written: no bootstrap code, no boot arguments;
%%% - the ROM window is write-protected; by default writes are dropped as on
%%%   real hardware (see sim1802_memory for the warn and trap modes).
%%% The pseudo-random values come from a seeded generator, so a run is still
%%% exactly reproducible; change the seed to see a different power-up state.

-module(sim1802_rom_loader).

-export([ load/4
        , format_error/1
        ]).

-spec load(string(), pos_integer(), non_neg_integer(), sim1802_memory:wp_mode())
          -> {ok, fun(() -> byte())} | {error, {module(), term()}}.
load(File, RomSize, Seed, WpMode) ->
  case file:read_file(File) of
    {ok, Bin} when byte_size(Bin) > RomSize ->
      {error, {?MODULE, {rom_image_too_large, byte_size(Bin), RomSize}}};
    {ok, Bin} ->
      write(0, Bin),
      fill(byte_size(Bin), RomSize, fun() -> 16#FF end),
      _ = rand:seed(exsss, {Seed, 16#1802, 16#C05}),
      RandByte = fun() -> rand:uniform(256) - 1 end,
      fill(RomSize, 65536, RandByte),
      sim1802_memory:write_protect(RomSize, WpMode),
      {ok, RandByte};
    {error, Reason} ->
      {error, {file, Reason}}
  end.

-spec format_error(term()) -> io_lib:chars().
format_error({rom_image_too_large, Size, RomSize}) ->
  io_lib:format("ROM image is ~p bytes, larger than the ~p-byte ROM", [Size, RomSize]);
format_error(Reason) ->
  io_lib:format("~tp", [Reason]).

write(_Address, <<>>) -> ok;
write(Address, <<Byte, Rest/binary>>) ->
  sim1802_memory:set_byte(Address, Byte),
  write(Address + 1, Rest).

fill(Address, End, _Fun) when Address >= End -> ok;
fill(Address, End, Fun) ->
  sim1802_memory:set_byte(Address, Fun()),
  fill(Address + 1, End, Fun).
