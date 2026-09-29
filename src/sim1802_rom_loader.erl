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
%%% - with Banks = {N, Port} (--banks N): the image is the fixed ROM
%%%   (padded to RomSize) followed by N 16 KiB banks for the window at
%%%   0x8000; the bank latch powers up with a random value (a real latch is
%%%   not reset), so start-up code must select a bank before using one.
%%% The pseudo-random values come from a seeded generator, so a run is still
%%% exactly reproducible; change the seed to see a different power-up state.

-module(sim1802_rom_loader).

-export([ load/5
        , format_error/1
        ]).

-spec load(string(), pos_integer(), non_neg_integer(), sim1802_memory:wp_mode(),
           none | {pos_integer(), 1..7})
          -> {ok, fun(() -> byte())} | {error, {module(), term()}}.
load(File, RomSize, Seed, WpMode, Banks) ->
  MaxSize =
    case Banks of
      none -> RomSize;
      {N, _Port} -> RomSize + N * 16#4000
    end,
  case file:read_file(File) of
    {ok, Bin} when byte_size(Bin) > MaxSize ->
      {error, {?MODULE, {rom_image_too_large, byte_size(Bin), MaxSize}}};
    {ok, Bin0} ->
      {Bin, BankBin} =
        case byte_size(Bin0) > RomSize of
          true -> split_binary(Bin0, RomSize);
          false -> {Bin0, <<>>}
        end,
      write(0, Bin),
      fill(byte_size(Bin), RomSize, fun() -> 16#FF end),
      _ = rand:seed(exsss, {Seed, 16#1802, 16#C05}),
      RandByte = fun() -> rand:uniform(256) - 1 end,
      fill(RomSize, 65536, RandByte),
      sim1802_memory:write_protect(RomSize, WpMode),
      case Banks of
        none -> ok;
        {_, _} -> sim1802_memory:init_banks(Banks, BankBin, RandByte())
      end,
      {ok, RandByte};
    {error, Reason} ->
      {error, {file, Reason}}
  end.

-spec format_error(term()) -> io_lib:chars().
format_error({rom_image_too_large, Size, RomSize}) ->
  io_lib:format("ROM image is ~p bytes, larger than the ~p-byte ROM (fixed part and banks)",
                [Size, RomSize]);
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
