%%% -*- erlang-indent-level: 2 -*-
%%%
%%% CDP1802 simulator

-module(sim1802).

-export([ main/1
        , format_error/1
        ]).

%% Command-line interface ======================================================

-spec main([string()]) -> no_return().
main(Args) ->
  main(Args, maps:new()).

%% TODO: use my getopt library here
main(["--debug" | Args], Map) -> main(Args, maps:put(debug, true, Map));
main(["-d" | Args], Map) -> main(Args, maps:put(debug, true, Map));
main(["--trace" | Args], Map) -> main(Args, maps:put(trace, true, Map));
main(["-t" | Args], Map) -> main(Args, maps:put(trace, true, Map));
%% cdp1802-nuttx fork options
main(["--cycles" | Args], Map) -> main(Args, maps:put(cycles, true, Map));
main(["--max-cycles", N | Args], Map) -> main(Args, maps:put(max_cycles, int_arg(N), Map));
main(["--pace", Hz | Args], Map) -> main(Args, maps:put(pace, int_arg(Hz), Map));
main(["--rom", File | Args], Map) -> main(Args, maps:put(rom, File, Map));
main(["--rom-size", N | Args], Map) -> main(Args, maps:put(rom_size, rom_size_arg(N), Map));
main(["--ram-seed", N | Args], Map) -> main(Args, maps:put(ram_seed, seed_arg(N), Map));
main(["--rom-writes", M | Args], Map) -> main(Args, maps:put(rom_writes, wp_mode_arg(M), Map));
main(["--banks", N | Args], Map) -> main(Args, maps:put(banks, banks_arg(N), Map));
main(["--bank-port", N | Args], Map) -> main(Args, maps:put(bank_port, port_arg(N), Map));
main(["--dump", File | Args], Map) -> main(Args, maps:put(dump, File, Map));
main(["--symbols", File | Args], Map) -> main(Args, maps:put(symbols, File, Map));
main([], #{rom := RomFile} = Map) ->
  run_rom(RomFile, Map);
main([Arg | _], #{rom := _}) ->
  io:format("Unexpected argument in --rom mode: ~s\n", [Arg]),
  halt(1);
main([ImageFile | Args], Map) ->
  ok = sim1802_memory:init(),
  SymTab = load(ImageFile, Args),
  ok = sim1802_io:init(),
  Core = sim1802_core:set_options(sim1802_core:init(maps:get(trace, Map, false), SymTab), Map),
  sim1802_debugger:run(Core, SymTab, Map);
main([], _Map) ->
  Progname = filename:basename(escript:script_name()),
  io:format("Usage: ~s [-d/--debug] [-t/--trace] [--cycles] [--max-cycles N] [--pace HZ]"
            " <executable> <arguments..>\n"
            "       ~s [options] --rom <image.bin> [--rom-size N] [--ram-seed N]"
            " [--rom-writes ignore|warn|trap] [--symbols <image.elf>]\n"
            "       [--banks N [--bank-port P]]  (16 KiB bank window at 0x8000, latch on OUT P, default 1)\n"
            "       [--dump FILE]  (write the 64 KiB address space to FILE on exit)\n",
            [Progname, Progname]),
  halt(1).

%% ROM mode (cdp1802-nuttx fork): boot a raw ROM image like a real board at
%% power-on.  See sim1802_rom_loader.
run_rom(RomFile, Map) ->
  ok = sim1802_memory:init(),
  RomSize = maps:get(rom_size, Map, 32768),
  Seed = maps:get(ram_seed, Map, 1802),
  WpMode = maps:get(rom_writes, Map, ignore),
  Banks =
    case maps:get(banks, Map, none) of
      none -> none;
      N when RomSize =< 16#8000 -> {N, maps:get(bank_port, Map, 1)};
      _ -> io:format("--banks needs --rom-size 32768 or less (window at 0x8000)\n"), halt(1)
    end,
  RandByte =
    case sim1802_rom_loader:load(RomFile, RomSize, Seed, WpMode, Banks) of
      {ok, Fun} -> Fun;
      {error, Reason} ->
        io:format("Error loading ~ts: ~ts\n", [RomFile, format_error(Reason)]),
        halt(1)
    end,
  SymTab =
    case maps:get(symbols, Map, false) of
      false -> sim1802_symtab:init([]);
      ElfFile ->
        case sim1802_elf_loader:load_symbols(ElfFile) of
          {ok, Syms} -> sim1802_symtab:init(maps:to_list(Syms));
          {error, Reason2} ->
            io:format("Error reading symbols from ~ts: ~ts\n", [ElfFile, format_error(Reason2)]),
            halt(1)
        end
    end,
  ok = sim1802_io:init(),
  Core0 = sim1802_core:init(maps:get(trace, Map, false), SymTab),
  Core = sim1802_core:set_options(sim1802_core:randomize_undefined(Core0, RandByte), Map),
  sim1802_debugger:run(Core, SymTab, Map).

rom_size_arg(String) ->
  case int_arg(String) of
    N when N =< 65536 -> N;
    _ -> usage_error(String)
  end.

banks_arg(String) ->
  case int_arg(String) of
    N when N =< 256 -> N;
    _ -> usage_error(String)
  end.

%% Ports 6 and 7 belong to the I/O controller.
port_arg(String) ->
  case int_arg(String) of
    N when N =< 5 -> N;
    _ -> usage_error(String)
  end.

seed_arg(String) ->
  try list_to_integer(String) of
    N when N >= 0 -> N;
    _ -> usage_error(String)
  catch error:badarg -> usage_error(String)
  end.

wp_mode_arg("ignore") -> ignore;
wp_mode_arg("warn") -> warn;
wp_mode_arg("trap") -> trap;
wp_mode_arg(String) -> usage_error(String).

int_arg(String) ->
  try list_to_integer(String) of
    N when N > 0 -> N;
    _ -> usage_error(String)
  catch error:badarg -> usage_error(String)
  end.

-spec usage_error(string()) -> no_return().
usage_error(String) ->
  io:format("Invalid numeric argument: ~s\n", [String]),
  halt(1).

%% Load image file and write boot args =========================================

load(ImageFile, Args) ->
  case sim1802_loader:load(ImageFile, Args) of
    {ok, SymTab} -> SymTab;
    {error, Reason} ->
      io:format("Error loading ~ts: ~ts\n", [ImageFile, format_error(Reason)]),
      halt(1)
  end.

%% Format errors ===============================================================

-spec format_error(term()) -> io_lib:chars().
format_error({Module, Reason} = Error) when is_atom(Module) ->
  case erlang:function_exported(Module, format_error, 1) of
    true ->
      try Module:format_error(Reason)
      catch _:_ -> default_format_error(Error)
      end;
    false -> default_format_error(Error)
  end;
format_error(Error) -> default_format_error(Error).

default_format_error(Error) ->
  io_lib:format("~tp", [Error]).
