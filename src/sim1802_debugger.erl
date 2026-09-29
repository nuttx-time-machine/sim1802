%%% -*- erlang-indent-level: 2 -*-
%%%
%%% Debugger for CDP1802 simulator

-module(sim1802_debugger).

-export([ run/3
        ]).

-export_type([ core/0
             ]).

-type core() :: sim1802_core:core().

-define(say(Fmt, Args), io:format(standard_error, Fmt, Args)).
-define(say(Str), ?say("~s", [Str])).

-record(cfg,
        { debug = false :: boolean()
        , singlestep = false :: boolean()
        , trace = false :: boolean()
        , breakpoints :: map()
        , symtab :: sim1802_symtab:symtab()
        , prev = "" :: string()
        , cycles = false :: boolean() % --cycles: report machine cycles on exit
        }).

%% API =========================================================================

-spec run(core(), sim1802_symtab:symtab(), map()) -> no_return().
run(Core, SymTab, Map) ->
  Cfg = cfg(SymTab, Map),
  case Cfg#cfg.debug of
    true -> debug(Core, Cfg);
    false -> execute(Core, Cfg)
  end.

%% Initialize configuration ====================================================

cfg(SymTab, Map) ->
  Trace = maps:get(trace, Map, false),
  Debug = maps:get(debug, Map, false),
  #cfg{ debug = Debug
      , singlestep = false
      , trace = Trace
      , breakpoints = maps:new()
      , symtab = SymTab
      , prev = ""
      , cycles = maps:get(cycles, Map, false)
      }.

%% Execute loop ================================================================

execute(Core, Cfg) ->
  case sim1802_core:step(Core) of
    {ok, NewCore} ->
      case Cfg#cfg.singlestep of
        true -> singlestep(NewCore, Cfg);
        false ->
          case is_breakpoint(NewCore, Cfg) of
            true -> breakpoint(NewCore, Cfg);
            false -> execute(NewCore, Cfg)
          end
      end;
    {error, {NewCore, Reason}} -> trap(NewCore, Reason, Cfg)
  end.

trap(Core, Reason, Cfg) ->
  case Reason of
    {halt, Status} ->
      case Cfg#cfg.debug of
        true ->
          ?say("! Exit ~p\n", [Status]),
          debug(Core, Cfg);
        false -> report_cycles(Core, Cfg), halt(Status)
      end;
    _ ->
      ?say("! Trap ~s\n", [Reason]),
      print_core(Core, Cfg),
      case Cfg#cfg.debug of
        true -> debug(Core, Cfg);
        false -> report_cycles(Core, Cfg), halt(97)
      end
  end.

report_cycles(Core, #cfg{cycles = true}) ->
  ?say("@ cycles ~p\n", [sim1802_core:get_cycles(Core)]);
report_cycles(_Core, _Cfg) ->
  ok.

singlestep(Core, Cfg) ->
  print_pc(get_pc(Core), Cfg),
  debug(Core, Cfg).

breakpoint(Core, Cfg) ->
  ?say("! Breakpoint: "),
  print_pc(get_pc(Core), Cfg),
  debug(Core, Cfg).

%% Debugger CLI ================================================================

debug(Core, Cfg) ->
  case io:get_line("dbg> ") of
    {error, Reason} ->
      ?say("I/O error: ~p\n", [Reason]),
      halt(1);
    eof ->
      ?say("EOF\n"),
      halt(1);
    Line ->
      case command(Line, Cfg) of
        {ok, {Prev, CmdFun, Rest}} -> CmdFun(Core, Rest, Cfg#cfg{prev = Prev});
        {error, Reason} -> cmd_error(Core, Reason, Cfg#cfg{prev = ""})
      end
  end.

cmd_error(Core, Reason, Cfg) ->
  ?say("Error: ~s\n", [Reason]),
  debug(Core, Cfg).

%% Split line into command and rest ============================================

command(Line, Cfg) ->
  case command(Line) of
    {ok, {CmdFun, Rest}} -> {ok, {Line, CmdFun, Rest}};
    {error, _Reason} = Error -> Error;
    false ->
      Prev = Cfg#cfg.prev,
      case command(Prev) of
        {ok, {CmdFun, Rest}} -> {ok, {Prev, CmdFun, Rest}};
        _ -> {ok, {"", fun cmd_nothing/3, ""}}
      end
  end.

command(Line) ->
  case token(Line) of
    {Token, Rest} ->
      case find(Token, commands(), []) of
        {ok, CmdFun} -> {ok, {CmdFun, Rest}};
        {error, _Reason} = Error -> Error
      end;
    false -> false
  end.

find(_Prefix, [], [Fun]) -> {ok, Fun};
find(Prefix, [], []) -> {error, io_lib:format("unknown command: ~s -- try help", [Prefix])};
find(Prefix, [], [_ | _]) -> {error, io_lib:format("ambiguous command: ~s", [Prefix])};
find(Prefix, [{Name, Fun, _Help} | Rest], Acc) ->
  case string:prefix(Name, Prefix) of
    nomatch -> find(Prefix, Rest, Acc);
    "" -> {ok, Fun};
    _ -> find(Prefix, Rest, [Fun | Acc])
  end.

commands() ->
  [ {"break", fun cmd_break/3, "break address -- set breakpoint at address"}
  , {"cont", fun cmd_cont/3, "continue executing the program"}
  , {"help", fun cmd_help/3, "list available commands"}
  , {"nobreak", fun cmd_nobreak/3, "nobreak address -- disable breakpoint at address"}
  , {"nostep", fun cmd_nostep/3, "disable single-step mode"}
  , {"pb", fun cmd_print_byte/3, "pb address -- print the byte at address"}
  , {"pc", fun cmd_print_core/3, "print the contents of the CPU core"}
  , {"pr", fun cmd_print_reg/3, "pr reg -- print the value in reg"}
  , {"pw", fun cmd_print_word/3, "pw address -- print the word at address"}
  , {"quit", fun cmd_quit/3, "quit the simulator"}
%  , {"sb", fun cmd_store_byte/3, "sb address byte -- store byte at address"}
%  , {"sr", fun cmd_store_reg/3, "sr reg word -- store word in reg"}
  , {"step", fun cmd_step/3, "enable single-step mode"}
%  , {"sw", fun cmd_store_word/3, "sw address word -- store word at address"}
  ].

%% Command: do nothing =========================================================

cmd_nothing(Core, _Line, Cfg) ->
  debug(Core, Cfg).

%% Command: cont(inue) =========================================================

cmd_cont(Core, _Line, Cfg) ->
  execute(Core, Cfg).

%% Command: quit ===============================================================

cmd_quit(_Core, _Line, _Cfg) ->
  halt(1).

%% Command: help ===============================================================

cmd_help(Core, _Line, Cfg) ->
  ?say("Available commands:\n"),
  lists:foreach(
    fun({Name, _Fun, Help}) ->
      ?say("~s\t~s\n", [Name, Help])
    end, commands()),
  debug(Core, Cfg).

%% Single-stepping =============================================================

cmd_step(Core, _Line, Cfg) ->
  debug(Core, Cfg#cfg{singlestep = true}).

cmd_nostep(Core, _Line, Cfg) ->
  debug(Core, Cfg#cfg{singlestep = false}).

%% Breakpoints =================================================================

cmd_break(Core, Line, Cfg) ->
  case word(Line) of
    {ok, {Address, _Rest}} ->
      Breakpoints0 = Cfg#cfg.breakpoints,
      Breakpoints = maps:put(Address, true, Breakpoints0),
      debug(Core, Cfg#cfg{breakpoints = Breakpoints});
    false -> cmd_error(Core, "no valid address", Cfg)
  end.

cmd_nobreak(Core, Line, Cfg) ->
  case word(Line) of
    {ok, {Address, _Rest}} ->
      Breakpoints0 = Cfg#cfg.breakpoints,
      Breakpoints = maps:remove(Address, Breakpoints0),
      debug(Core, Cfg#cfg{breakpoints = Breakpoints});
    false -> cmd_error(Core, "no valid address", Cfg)
  end.

is_breakpoint(Core, Cfg) ->
  maps:is_key(get_pc(Core), Cfg#cfg.breakpoints).

%% Print =======================================================================

cmd_print_byte(Core, Line, Cfg) ->
  case word(Line) of
    {ok, {Address, _Rest}} ->
      Byte = get_byte(Core, Address),
      print_byte(Byte),
      debug(Core, Cfg);
    false -> cmd_error(Core, "no valid address", Cfg)
  end.

cmd_print_core(Core, _Line, Cfg) ->
  print_core(Core, Cfg),
  debug(Core, Cfg).

cmd_print_reg(Core, Line, Cfg) ->
  case reg(Line) of
    {ok, {Reg, _Rest}} ->
      print_reg(Core, Reg, Cfg),
      debug(Core, Cfg);
    false -> cmd_error(Core, "no valid reg", Cfg)
  end.

cmd_print_word(Core, Line, Cfg) ->
  case word(Line) of
    {ok, {Address, _Rest}} ->
      Word = get_word(Core, Address),
      print_word(Word),
      debug(Core, Cfg);
    false -> cmd_error(Core, "no valid address", Cfg)
  end.

print_core(Core, Cfg) ->
  lists:foreach(
    fun(Reg) ->
      ?say("r~.10.0b\t", [Reg]),
      print_reg(Core, Reg, Cfg)
    end, lists:seq(0, 15)),
  ?say("d\t"),
  print_reg(Core, d, Cfg),
  ?say("df\t"),
  print_reg(Core, df, Cfg),
  ?say("p\t"),
  print_reg(Core, p, Cfg),
  ?say("x\t"),
  print_reg(Core, x, Cfg).

print_reg(Core, Reg, Cfg) ->
  case Reg of
    d -> print_byte(get_d(Core));
    df -> print_decimal(get_df(Core));
    p -> print_decimal(get_p(Core));
    x -> print_decimal(get_x(Core));
    _ ->
      Word = get_r(Core, Reg),
      P = get_p(Core),
      case (Reg =:= P) orelse (Reg >= 3 andalso Reg =< 6) of
        true -> print_pc(Word, Cfg);
        false -> print_word(Word)
      end
  end.

print_pc(Word, Cfg) ->
  Suffix =
    case sim1802_symtab:resolve(Cfg#cfg.symtab, Word) of
      {Name, Offset} -> io_lib:format(" ~s+~.16.0b", [Name, Offset]);
      false -> ""
    end,
  ?say("0x~4.16.0B~s\n", [Word, Suffix]).

print_decimal(Num) ->
  ?say("~.10.0b\n", [Num]).

print_byte(Byte) ->
  ?say("0x~2.16.0B\n", [Byte]).

print_word(Word) ->
  ?say("0x~4.16.0B\n", [Word]).

%% Split line into a register and rest =========================================

reg(Line) ->
  case skip_blanks(Line) of
    [] -> false;
    [$d, $f | Rest] -> reg(df, Rest);
    [$d | Rest] -> reg(d, Rest);
    [$p | Rest] -> reg(p, Rest);
    [$x | Rest] -> reg(x, Rest);
    [$r | Rest] ->
      case strtol:parse(Rest, 10) of
        {ok, {Reg, Rest2}} when Reg >= 0, Reg < 16 -> reg(Reg, Rest2);
        {error, _Reason} -> false
      end
  end.

reg(Reg, Rest) ->
  case Rest of
    [] -> {ok, {Reg, Rest}};
    [Ch | _] ->
      case isblank(Ch) of
        true -> {ok, {Reg, Rest}};
        false -> false
      end
  end.

%% Split line into a 16-bit word and rest ======================================

word(Line) ->
  case token(Line) of
    {Token, Rest} ->
      case strtol:parse(Token, 0) of
        {ok, {Word, []}} when Word >= 0, Word < 65536 -> {ok, {Word, Rest}};
        {error, _Reason} -> false
      end;
    false -> false
  end.

%% Split line into first token and rest ========================================

token(Line) ->
  case skip_blanks(Line) of
    [] -> false;
    [Ch | Rest] -> token(Rest, [Ch])
  end.

token(Line, Acc) ->
  case Line of
    [] -> {lists:reverse(Acc), Line};
    [Ch | Rest] ->
      case isblank(Ch) of
        true -> {lists:reverse(Acc), Line};
        false -> token(Rest, [Ch | Acc])
      end
  end.

%% Skip leading blanks =========================================================

skip_blanks(Line) ->
  case Line of
    [] -> Line;
    [Ch | Rest] ->
      case isblank(Ch) of
        true -> skip_blanks(Rest);
        false -> Line
      end
  end.

isblank($\s) -> true;
isblank($\t) -> true;
isblank($\n) -> true;
isblank($\r) -> true;
isblank(_  ) -> false.

%% CPU core accessors ==========================================================

get_byte(Core, Address) ->
  sim1802_core:get_byte(Core, Address).

get_word(Core, Address) ->
  sim1802_core:get_word(Core, Address).

get_pc(Core) ->
  get_r(Core, get_p(Core)).

get_d(Core) ->
  sim1802_core:get_d(Core).

get_df(Core) ->
  sim1802_core:get_df(Core).

get_p(Core) ->
  sim1802_core:get_p(Core).

get_r(Core, N) ->
  sim1802_core:get_r(Core, N).

get_x(Core) ->
  sim1802_core:get_x(Core).
