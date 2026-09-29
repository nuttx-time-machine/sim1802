%%% -*- erlang-indent-level: 2 -*-
%%%
%%% ELF file loader for CDP1802 simulator

-module(sim1802_elf_loader).

-export([ load/1
        , format_error/1
        ]).

%% API =========================================================================

-spec load(string()) -> {ok, sim1802_symtab:symtab()} | false | {error, {module(), term()}}.
load(File) ->
  case file:open(File, [read, raw, read_ahead]) of
    {ok, Fd} ->
      try
        case load_fd(Fd) of
          {ok, {PC, SymTab}} ->
            install_bootstrap(PC),
            set_write_protect(SymTab),
            {ok, sim1802_symtab:init(maps:to_list(SymTab))};
          FalseOrError -> FalseOrError
        end
      after
        file:close(Fd)
      end;
    {error, Reason} -> {error, {file, Reason}}
  end.

%% Write-protect .text and .rodata =============================================

set_write_protect(SymTab) ->
  case find_end_of_text_and_rodata(SymTab) of
    false -> ok;
    Limit -> sim1802_memory:write_protect(Limit)
  end.

%% cdp1802-nuttx fork: an image may define __sim1802_rom_end to say exactly
%% where its read-only region ends, e.g. to emulate a board with 32 KiB of
%% ROM.  Otherwise fall back to the libc-specific symbols as before.
find_end_of_text_and_rodata(SymTab) ->
  case maps:get("__sim1802_rom_end", SymTab, false) of
    false ->
      case maps:get("__DTOR_END__", SymTab, false) of
        false -> maps:get("_fini", SymTab, false);
        Address -> Address
      end;
    RomEnd -> RomEnd
  end.

%% Install bootstrap ===========================================================
%%
%% Write bootstrap code at address 0:
%% - disable interrupts
%% - jump to ELF start address

-define(OP_DIS,  16#71). % DISABLE
-define(OP_LBR,  16#C0). % LONG BRANCH

-define(BOOTSTRAP_SIZE, 5).

install_bootstrap(_PC = 0) ->
  ok;
install_bootstrap(PC) when PC < ?BOOTSTRAP_SIZE ->
  {error, {?MODULE, {unsupported_entry_point, PC}}};
install_bootstrap(PC) ->
  Bootstrap =
    [ ?OP_DIS, 16#00 % disable interrupts
    , ?OP_LBR, PC bsr 8, PC band 255 % jump to PC
    ],
  ?BOOTSTRAP_SIZE = length(Bootstrap), % assert
  write_bytes(0, Bootstrap).

%% ELF32 types and macros ======================================================

-define(UINT8_MAX, ((1 bsl 8) - 1)).
-type uint8_t() :: 0..?UINT8_MAX.

-define(UINT16_MAX, ((1 bsl 16) - 1)).
-type uint16_t() :: 0..?UINT16_MAX.

-define(UINT32_MAX, ((1 bsl 32) - 1)).
-type uint32_t() :: 0..?UINT32_MAX.

-type elf32_Addr()  :: uint32_t().
-type elf32_Half()  :: uint16_t().
-type elf32_Off()   :: uint32_t().
-type elf32_Uchar() :: uint8_t().
-type elf32_Word()  :: uint32_t().

%% ELF Header

-define(EI_NIDENT, 16).

-record(elf32_Ehdr,
        { e_ident       :: [elf32_Uchar()]      % ELF magic, ?EI_NIDENT elements
        , e_type        :: elf32_Half()         % Identifies object file type
        , e_machine     :: elf32_Half()         % Specifies required architecture
        , e_version     :: elf32_Word()         % Identifies object file version
        , e_entry       :: elf32_Addr()         % Entry point virtual address
        , e_phoff       :: elf32_Off()          % Program header table file offset
        , e_shoff       :: elf32_Off()          % Section header table file offset
        , e_flags       :: elf32_Word()         % Processor-specific flags
        , e_ehsize      :: elf32_Half()         % ELF header size in bytes
        , e_phentsize   :: elf32_Half()         % Program header table entry size
        , e_phnum       :: elf32_Half()         % Program header table entry count
        , e_shentsize   :: elf32_Half()         % Section header table entry size
        , e_shnum       :: elf32_Half()         % Section header table entry count
        , e_shstrndx    :: elf32_Half()         % Section header string table index
        }).

-define(ELF32_EHDR_SIZEOF, (8 * 2 + 5 * 4 + ?EI_NIDENT)).

%% e_ident[] identification indexes

-define(EI_MAG0,          0). % File identification byte 0 index
-define(EI_MAG1,          1). % File identification byte 1 index
-define(EI_MAG2,          2). % File identification byte 2 index
-define(EI_MAG3,          3). % File identification byte 3 index
-define(EI_CLASS,         4). % File class
-define(EI_DATA,          5). % Data encoding
-define(EI_VERSION,       6). % File version
-define(EI_OSABI,         7). % Operating System/ABI indication
-define(EI_ABIVERSION,    8). % ABI version
-define(EI_PAD,           9). % Start of padding bytes

-define(ELFMAG0,      16#7F). % Magic number byte 0
-define(ELFMAG1,         $E). % Magic number byte 1
-define(ELFMAG2,         $L). % Magic number byte 2
-define(ELFMAG3,         $F). % Magic number byte 3

-define(ELFCLASS32,       1). % 32-bit objects

-define(ELFDATA2MSB,      2). % 2's complement, big endian

-define(ELFOSABI_NONE,    0). % UNIX System V ABI

%% Values for e_type, which identifies the object file type.

-define(ET_EXEC,          2). % Position-dependent executable file

%% Values for e_machine, which identifies the architecture.  These numbers
%% are officially assigned by registry@sco.com.  See below for a list of
%% ad-hoc numbers used during initial development.

%% Values for e_version.

-define(EV_CURRENT,       1). % Current version

%% Value for e_phnum.
-define(PN_XNUM,    16#ffff). % Extended numbering

%% Section header

-record(elf32_Shdr,
        { sh_name       :: elf32_Word()         % Section name, index in string tbl
                         | string()             % Name (in-core only)
        , sh_type       :: elf32_Word()         % Type of section
        , sh_flags      :: elf32_Word()         % Miscellaneous section attributes
        , sh_addr       :: elf32_Addr()         % Section virtual addr at execution
        , sh_offset     :: elf32_Off()          % Section file offset
        , sh_size       :: elf32_Word()         % Size of section in bytes
        , sh_link       :: elf32_Word()         % Index of another section
        , sh_info       :: elf32_Word()         % Additional section information
        , sh_addralign  :: elf32_Word()         % Section alignment
        , sh_entsize    :: elf32_Word()         % Entry size if section holds table
        }).

-define(ELF32_SHDR_SIZEOF, (10 * 4)).

%% Special section indices, which may show up in st_shndx fields, among
%% other places.

-define(SHN_UNDEF,      16#0000).       % Undefined, missing, irrelevant, or meaningless

%% Values for section header, sh_type field.

-define(SHT_SYMTAB,     2).             % Link editing symbol table
-define(SHT_STRTAB,     3).             % A string table

%% Program header

-record(elf32_Phdr,
        { p_type        :: elf32_Word() % Identifies program segment type
        , p_offset      :: elf32_Off()  % Segment file offset
        , p_vaddr       :: elf32_Addr() % Segment virtual address
        , p_paddr       :: elf32_Addr() % Segment physical address
        , p_filesz      :: elf32_Word() % Segment size in file
        , p_memsz       :: elf32_Word() % Segment size in memory
        , p_flags       :: elf32_Word() % Segment flags
        , p_align       :: elf32_Word() % Segment alignment, file & memory
        }).

-define(ELF32_PHDR_SIZEOF, (8 * 4)).

%% Values for program header, p_type field.

-define(PT_NULL,          0). % Program header table entry unused
-define(PT_LOAD,          1). % Loadable program segment

%% Symbol table entry

-record(elf32_Sym,
        { st_name       :: elf32_Word()         % Symbol name, index in string tbl
                         | string()             % Name (in-core only)
        , st_value      :: elf32_Addr()         % Value of the symbol
        , st_size       :: elf32_Word()         % Associated symbol size
        , st_info       :: elf32_Uchar()        % Type and binding attributes
        , st_other      :: elf32_Uchar()        % No defined meaning, 0
        , st_shndx      :: elf32_Half()         % Associated section index
        }).

-define(ELF32_SYM_SIZEOF,       (3 * 4 + 2 + 1 + 1)).

%% RCA CDP1802 specifics

-define(EM_CDP1802, 16#1802).
-define(PAGE_SIZE,      256).

%% Load ELF executable =========================================================

-spec load_fd(file:fd()) -> {ok, {PC :: non_neg_integer(), map()}} | false | {error, {module(), term()}}.
load_fd(Fd) ->
  case read_Ehdr(Fd) of
    {ok, Ehdr} ->
      case load_ehdr(Fd, Ehdr) of
       {ok, PC} ->
         SymTab =
           case load_SymTab(Fd, Ehdr) of
             {ok, SymTab0} -> SymTab0;
             {error, Reason} ->
               io:format(standard_error, "No symbol table loaded: ~ts\n", [sim1802:format_error(Reason)]),
               maps:new()
           end,
         {ok, {PC, SymTab}};
       {error, _Reason} = Error -> Error
      end;
    {error, {?MODULE, {wrong_ei_mag, _}}} -> false;
    {error, {?MODULE, eof}} -> false;
    {error, _Reason} = Error -> Error
  end.

load_ehdr(Fd, Ehdr) ->
  ?ET_EXEC = Ehdr#elf32_Ehdr.e_type, % assert
  case read_PhTab(Fd, Ehdr) of
    {ok, PhTab} -> load_phtab(Fd, Ehdr, PhTab, _PhdrIx = 0);
    {error, _Reason} = Error -> Error
  end.

load_phtab(_Fd, Ehdr, _PhTab = [], _PhdrIx) ->
  {ok, Ehdr#elf32_Ehdr.e_entry};
load_phtab(Fd, Ehdr, [Phdr | PhTab], PhdrIx) ->
  case load_phdr(Fd, Phdr, PhdrIx) of
    ok -> load_phtab(Fd, Ehdr, PhTab, PhdrIx + 1);
    {error, _Reason} = Error -> Error
  end.

load_phdr(Fd, Phdr, PhdrIx) ->
  case Phdr#elf32_Phdr.p_type of
    ?PT_NULL -> ok;
    ?PT_LOAD ->
      case is_valid_phdr(Phdr) of
        true -> load_phdr(Fd, Phdr);
        false -> {error, {?MODULE, {invalid_phdr, PhdrIx}}}
      end;
    _PType -> {error, {?MODULE, {invalid_phdr, PhdrIx}}}
  end.

load_phdr(Fd, Phdr) ->
  #elf32_Phdr{ p_offset = Offset
             , p_vaddr = VAddr
             , p_filesz = FileSz
             } = Phdr,
  case VAddr + FileSz =< 65536 - 256 of
    true ->
      case seek(Fd, Offset) of
        ok -> copy_file_to_core(Fd, VAddr, FileSz);
        {error, _Reason} = Error -> Error
      end;
    false -> {error, {?MODULE, program_too_large}}
  end.

copy_file_to_core(_Fd, _VAddr, _FileSz = 0) -> ok;
copy_file_to_core(Fd, VAddr, FileSz) ->
  case read_byte(Fd) of
    {ok, Byte} ->
      write_byte(VAddr, Byte),
      copy_file_to_core(Fd, VAddr + 1, FileSz - 1);
    {error, _Reason} = Error -> Error
  end.

is_valid_phdr(Phdr) ->
  #elf32_Phdr{ p_offset = _Offset
             , p_vaddr = _VAddr
             , p_filesz = FileSz
             , p_memsz = MemSz
             , p_flags = Flags
             } = Phdr,
%  is_page_aligned(Offset) andalso
%  is_page_aligned(VAddr) andalso
  MemSz >= FileSz andalso
  no_excess_flags(Flags).

%is_page_aligned(Offset) -> (Offset band (?PAGE_SIZE - 1)) =:= 0.

no_excess_flags(Flags) -> (Flags band 8#7) =:= Flags.

%% Load ELF Symbol Table =======================================================

load_SymTab(Fd, Ehdr) ->
  case read_ShTab(Fd, Ehdr) of
    {ok, ShTab} ->
      case read_SymTab(Fd, ShTab) of
        {ok, {SymTab, _ShNdx}} -> load_SymTab(SymTab);
        {error, _Reason} = Error -> Error
      end;
    {error, _Reason} = Error -> Error
  end.

load_SymTab(SymTab) ->
  Bindings =
    lists:map(
      fun(#elf32_Sym{st_name = StName, st_value = StValue}) ->
        {StName, StValue}
      end, SymTab),
  {ok, maps:from_list(Bindings)}.

%% Writing to memory ===========================================================

write_bytes(_Address, []) ->
  ok;
write_bytes(Address, [Byte | Bytes]) ->
  write_byte(Address, Byte),
  write_bytes(Address + 1, Bytes).

write_byte(Address, Byte) ->
  sim1802_memory:set_byte(Address, Byte).

%% Read ELF Header =============================================================

read_Ehdr(Fd) ->
  Tag = elf32_Ehdr,
  Fields =
    [ fun read_e_ident/1        % e_ident
    , fun read_Half/1           % e_type
    , fun read_Half/1           % e_machine
    , fun read_Word/1           % e_version
    , fun read_Addr/1           % e_entry
    , fun read_Off/1            % e_phoff
    , fun read_Off/1            % e_shoff
    , fun read_Word/1           % e_flags
    , fun read_Half/1           % e_ehsize
    , fun read_Half/1           % e_phentsize
    , fun read_Half/1           % e_phnum
    , fun read_Half/1           % e_shentsize
    , fun read_Half/1           % e_shnum
    , fun read_Half/1           % e_shstrndx
    ],
  case read_record(Fd, Tag, Fields) of
    {ok, Ehdr} = Result ->
      case check_Ehdr(Ehdr) of
        ok -> Result;
        {error, _Reason} = Error -> Error
      end;
    {error, _Reason} = Error -> Error
  end.

read_e_ident(Fd) ->
  read(Fd, ?EI_NIDENT).

check_Ehdr(Ehdr) ->
  Checks =
    [ fun check_Ehdr_ei_mag/1
    , fun check_Ehdr_ei_class/1
    , fun check_Ehdr_ei_data/1
    , fun check_Ehdr_ei_version/1
    , fun check_Ehdr_ei_osabi/1
    , fun check_Ehdr_ei_abiversion/1
    , fun check_Ehdr_ei_pad/1
    , fun check_Ehdr_e_type/1
    , fun check_Ehdr_e_machine/1
    , fun check_Ehdr_e_version/1
    , fun check_Ehdr_e_ehsize/1
    , fun check_Ehdr_e_phentsize/1
    , fun check_Ehdr_e_shentsize/1
    ],
  check(Ehdr, Checks).

check(_X, []) -> ok;
check(X, [Check | Checks]) ->
  case Check(X) of
    ok -> check(X, Checks);
    {error, _Reason} = Error -> Error
  end.

check_Ehdr_ei_mag(Ehdr) ->
  #elf32_Ehdr{e_ident = Ident} = Ehdr,
  {Mag, _} = lists:split(4, Ident),
  case Mag of
    [?ELFMAG0, ?ELFMAG1, ?ELFMAG2, ?ELFMAG3] -> ok;
    _ -> {error, {?MODULE, {wrong_ei_mag, Mag}}}
  end.

check_Ehdr_ei_class(Ehdr) ->
  #elf32_Ehdr{e_ident = Ident} = Ehdr,
  Class = lists:nth(?EI_CLASS + 1, Ident),
  case Class of
    ?ELFCLASS32 -> ok;
    _ -> {error, {?MODULE, {wrong_ei_class, Class}}}
  end.

check_Ehdr_ei_data(Ehdr) ->
  #elf32_Ehdr{e_ident = Ident} = Ehdr,
  Data = lists:nth(?EI_DATA + 1, Ident),
  case Data of
    ?ELFDATA2MSB -> ok;
    _ -> {error, {?MODULE, {wrong_ei_data, Data}}}
  end.

check_Ehdr_ei_version(Ehdr) ->
  #elf32_Ehdr{e_ident = Ident} = Ehdr,
  Version = lists:nth(?EI_VERSION + 1, Ident),
  case Version of
    ?EV_CURRENT -> ok;
    _ -> {error, {?MODULE, {wrong_ei_version, Version}}}
  end.

check_Ehdr_ei_osabi(Ehdr) ->
  #elf32_Ehdr{e_ident = Ident} = Ehdr,
  OSABI = lists:nth(?EI_OSABI + 1, Ident),
  case OSABI of
    ?ELFOSABI_NONE -> ok;
    _ -> {error, {?MODULE, {wrong_ei_osabi, OSABI}}}
  end.

check_Ehdr_ei_abiversion(Ehdr) ->
  #elf32_Ehdr{e_ident = Ident} = Ehdr,
  ABIVersion = lists:nth(?EI_ABIVERSION + 1, Ident),
  case ABIVersion of
    0 -> ok;
    _ -> {error, {?MODULE, {wrong_ei_abiversion, ABIVersion}}}
  end.

check_Ehdr_ei_pad(Ehdr) ->
  #elf32_Ehdr{e_ident = Ident} = Ehdr,
  Pad = lists:nthtail(?EI_PAD, Ident),
  Zeroes = lists:duplicate(?EI_NIDENT - ?EI_PAD, 0),
  case Pad of
    Zeroes -> ok;
    _ -> {error, {?MODULE, {wrong_ei_pad, Pad}}}
  end.

check_Ehdr_e_type(Ehdr) ->
  #elf32_Ehdr{e_type = Type} = Ehdr,
  case Type of
    ?ET_EXEC -> ok;
    _ -> {error, {?MODULE, {wrong_e_type, Type}}}
  end.

check_Ehdr_e_machine(Ehdr) ->
  #elf32_Ehdr{e_machine = Machine} = Ehdr,
  case Machine of
    ?EM_CDP1802 -> ok;
    _ -> {error, {?MODULE, {wrong_e_machine, Machine}}}
  end.

check_Ehdr_e_version(Ehdr) ->
  #elf32_Ehdr{e_version = Version} = Ehdr,
  case Version of
    ?EV_CURRENT -> ok;
    _ -> {error, {?MODULE, {wrong_e_version, Version}}}
  end.

check_Ehdr_e_ehsize(Ehdr) ->
  #elf32_Ehdr{e_ehsize = EhSize} = Ehdr,
  case EhSize of
    ?ELF32_EHDR_SIZEOF -> ok;
    _ -> {error, {?MODULE, {wrong_e_ehsize, EhSize}}}
  end.

check_Ehdr_e_phentsize(Ehdr) ->
  #elf32_Ehdr{e_phoff = PhOff, e_phentsize = PhEntSize} = Ehdr,
  case {PhOff, PhEntSize} of
    {0, _} -> ok;
    {_, ?ELF32_PHDR_SIZEOF} -> ok;
    _ -> {error, {?MODULE, {wrong_e_phentsize, PhEntSize}}}
  end.

check_Ehdr_e_shentsize(Ehdr) ->
  #elf32_Ehdr{e_shoff = ShOff, e_shentsize = ShEntSize} = Ehdr,
  case {ShOff, ShEntSize} of
    {0, _} -> ok;
    {_, ?ELF32_SHDR_SIZEOF} -> ok;
    _ -> {error, {?MODULE, {wrong_e_shentsize, ShEntSize}}}
  end.

%% Read ELF Program Header Table ===============================================

read_PhTab(Fd, Ehdr) ->
  PhNum = get_phnum(Ehdr),
  #elf32_Ehdr{e_phoff = PhOff} = Ehdr,
  case PhOff =:= 0 orelse PhNum =:= 0 of
    true -> {ok, []};
    false ->
      case seek(Fd, PhOff) of
        ok -> read_PhTab(Fd, PhNum, []);
        {error, _Reason} = Error -> Error
      end
  end.

read_PhTab(_Fd, 0, Acc) -> {ok, lists:reverse(Acc)};
read_PhTab(Fd, PhNum, Acc) when PhNum > 0 ->
  case read_Phdr(Fd) of
    {ok, Phdr} -> read_PhTab(Fd, PhNum - 1, [Phdr | Acc]);
    {error, _Reason} = Error -> Error
  end.

get_phnum(Ehdr) ->
  #elf32_Ehdr{e_phnum = PhNum} = Ehdr,
  %% TODO: if PhNum =:= ?PN_XNUM the real PhNum is stored in Shdr0.sh_info
  true = PhNum =/= ?PN_XNUM,
  PhNum.

read_Phdr(Fd) ->
  Tag = elf32_Phdr,
  Fields =
    [ fun read_Word/1           % p_type
    , fun read_Off/1            % p_offset
    , fun read_Addr/1           % p_vaddr
    , fun read_Addr/1           % p_paddr
    , fun read_Word/1           % p_filesz
    , fun read_Word/1           % p_memsz
    , fun read_Word/1           % p_flags
    , fun read_Word/1           % p_align
    ],
  read_record(Fd, Tag, Fields).

%% Read ELF Section Header Table ===============================================

read_ShTab(Fd, Ehdr) ->
  #elf32_Ehdr{ e_shoff = ShOff
             , e_shnum = ShNum0
             } = Ehdr,
  case ShOff of
    0 -> {ok, []};
    _ ->
      case seek(Fd, ShOff) of
        ok ->
          case read_Shdr(Fd) of
            {ok, Shdr0} ->
              ShNum = actual_shnum(ShNum0, Shdr0),
              read_ShTab(Fd, ShNum - 1, [Shdr0]);
            {error, _Reason} = Error -> Error
          end;
        {error, _Reason} = Error -> Error
      end
  end.

actual_shnum(0, #elf32_Shdr{sh_size = ShNum} = _Shdr0) -> ShNum;
actual_shnum(ShNum, _Shdr0) -> ShNum.

read_ShTab(_Fd, 0, Shdrs) -> {ok, lists:reverse(Shdrs)};
read_ShTab(Fd, ShNum, Shdrs) when ShNum > 0 ->
  case read_Shdr(Fd) of
    {ok, Shdr} -> read_ShTab(Fd, ShNum - 1, [Shdr | Shdrs]);
    {error, _Reason} = Error -> Error
  end.

read_Shdr(Fd) ->
  Tag = elf32_Shdr,
  Fields =
    [ fun read_Word/1           % sh_name
    , fun read_Word/1           % sh_type
    , fun read_Word/1           % sh_flags
    , fun read_Addr/1           % sh_addr
    , fun read_Off/1            % sh_offset
    , fun read_Word/1           % sh_size
    , fun read_Word/1           % sh_link
    , fun read_Word/1           % sh_info
    , fun read_Word/1           % sh_addralign
    , fun read_Word/1           % sh_entsize
    ],
  read_record(Fd, Tag, Fields).

%% Read ELF String Table =======================================================

read_StrTab(Fd, ShTab, Index) ->
  ShNum = length(ShTab),
  case Index > 0 andalso Index < ShNum of
    true ->
      #elf32_Shdr{ sh_type = ShType
                 , sh_size = ShSize
                 , sh_offset = ShOffset
                 } = lists:nth(Index + 1, ShTab),
      case ShType of
        ?SHT_STRTAB ->
          case seek(Fd, ShOffset) of
            ok -> read(Fd, ShSize);
            {error, _Reason} = Error -> Error
          end;
        _ -> {error, {?MODULE, {wrong_strtab_sh_type, ShType, Index}}}
      end;
    false -> {error, {?MODULE, {wrong_strtab_index, Index}}}
  end.

get_name(_StrTab, 0) -> {ok, ""}; % TODO: or some marker for "absent"
get_name(StrTab, Index) ->
  try lists:nthtail(Index, StrTab) of
    [C | Tail] -> get_name(C, Tail, [])
  catch _C:_R ->
    {error, {?MODULE, {wrong_index_in_strtab, Index}}}
  end.

get_name(0, _Tail, Acc) -> {ok, lists:reverse(Acc)};
get_name(C1, [C2 | Tail], Acc) -> get_name(C2, Tail, [C1 | Acc]);
get_name(_C, [], _Acc) -> {error, {?MODULE, strtab_not_nul_terminated}}.

%% Read ELF Symbol Table =======================================================

read_SymTab(Fd, ShTab) ->
  case find_SymTab(ShTab) of
    false -> {ok, {[], ?SHN_UNDEF}};
    {ok, {Shdr, ShNdx}} ->
      #elf32_Shdr{ sh_link = ShLink
                 , sh_entsize = ShEntSize
                 , sh_size = ShSize
                 , sh_offset = ShOffset
                 } = Shdr,
      if ShEntSize =/= ?ELF32_SYM_SIZEOF ->
           {error, {?MODULE, {wrong_symtab_sh_entsize, ShEntSize}}};
         (ShSize rem ?ELF32_SYM_SIZEOF) =/= 0 ->
           {error, {?MODULE, {wrong_symtab_sh_size, ShSize}}};
         true ->
           case read_StrTab(Fd, ShTab, ShLink) of
             {ok, StrTab} ->
               SymNum = ShSize div ?ELF32_SYM_SIZEOF,
               case SymNum of
                 0 -> {ok, {[], ShNdx}};
                 _ ->
                   case seek(Fd, ShOffset) of
                     ok ->
                       case read_SymTab(Fd, SymNum, []) of
                         {ok, SymTab} ->
                           case read_SymTab_names(SymTab, StrTab) of
                             {ok, NewSymTab} -> {ok, {NewSymTab, ShNdx}};
                             {error, _Reason} = Error -> Error
                           end;
                         {error, _Reason} = Error -> Error
                       end;
                     {error, _Reason} = Error -> Error
                   end
               end;
             {error, _Reason} = Error -> Error
           end
      end
  end.

read_SymTab(_Fd, _SymNum = 0, Syms) -> {ok, lists:reverse(Syms)};
read_SymTab(Fd, SymNum, Syms) when SymNum > 0 ->
  case read_Sym(Fd) of
    {ok, Sym} -> read_SymTab(Fd, SymNum - 1, [Sym | Syms]);
    {error, _Reason} = Error -> Error
  end.

find_SymTab(ShTab) -> find_SymTab(ShTab, 0).

find_SymTab([], _I) -> false;
find_SymTab([#elf32_Shdr{sh_type = ?SHT_SYMTAB} = Shdr | _], I) -> {ok, {Shdr, I}};
find_SymTab([_Shdr | ShTab], I) -> find_SymTab(ShTab, I + 1).

read_SymTab_names(SymTab, StrTab) ->
  read_SymTab_names(SymTab, StrTab, []).

read_SymTab_names(_SymTab = [], _StrTab, Acc) -> {ok, lists:reverse(Acc)};
read_SymTab_names([Sym | SymTab], StrTab, Acc) ->
  case read_Sym_name(Sym, StrTab) of
    {ok, NewSym} -> read_SymTab_names(SymTab, StrTab, [NewSym | Acc]);
    {error, _Reason} = Error -> Error
  end.

read_Sym_name(Sym = #elf32_Sym{st_name = StName}, StrTab) ->
  case get_name(StrTab, StName) of
    {ok, Name} -> {ok, Sym#elf32_Sym{st_name = Name}};
    {error, _Reason} = Error -> Error
  end.

read_Sym(Fd) ->
  Tag = elf32_Sym,
  Fields =
    [ fun read_Word/1           % st_name
    , fun read_Addr/1           % st_value
    , fun read_Word/1           % st_size
    , fun read_Uchar/1          % st_info
    , fun read_Uchar/1          % st_other
    , fun read_Half/1           % st_shndx
    ],
  read_record(Fd, Tag, Fields).

%% Reading records from binary file ============================================

read_record(Fd, Tag, Fields) ->
  do_read_record(Fields, Fd, [Tag]).

do_read_record([ReadField | Fields], Fd, Values) ->
  case ReadField(Fd) of
    {ok, Value} -> do_read_record(Fields, Fd, [Value | Values]);
    {error, _Reason} = Error -> Error
  end;
do_read_record([], _Fd, Values) ->
  {ok, list_to_tuple(lists:reverse(Values))}.

%% Reading scalars from binary file ============================================

read_Addr(Fd)  -> read_uint32(Fd).
read_Half(Fd)  -> read_uint16(Fd).
read_Off(Fd)   -> read_uint32(Fd).
read_Uchar(Fd) -> read_byte(Fd).
read_Word(Fd)  -> read_uint32(Fd).

read_uint16(Fd) -> read_uint(Fd, 2, fun make_uint16/1).
read_uint32(Fd) -> read_uint(Fd, 4, fun make_uint32/1).

make_uint16([B0, B1]) -> % big-endian
  (B0 bsl 8) bor B1.

make_uint32([B0, B1, B2, B3]) -> % big-endian
  (B0 bsl 24) bor (B1 bsl 16) bor (B2 bsl 8) bor B3.

read_uint(Fd, N, ConvFun) ->
  case read(Fd, N) of
    {ok, Bytes} -> {ok, ConvFun(Bytes)};
    {error, _Reason} = Error -> Error
  end.

read(Fd, N) -> read(Fd, N, []).

read(_Fd, 0, Acc) -> {ok, lists:reverse(Acc)};
read(Fd, N, Acc) ->
  case read_byte(Fd) of
    {ok, Byte} -> read(Fd, N - 1, [Byte | Acc]);
    {error, _Reason} = Error -> Error
  end.

read_byte(Fd) ->
  case file:read(Fd, 1) of
    {ok, [Byte]} -> {ok, Byte};
    eof -> {error, {?MODULE, eof}};
    {error, Reason} -> {error, {file, Reason}}
  end.

seek(Fd, Offset) ->
  case file:position(Fd, {bof, Offset}) of
    {ok, _} -> ok;
    {error, Reason} -> {error, {file, Reason}}
  end.

%% Error formatting ============================================================

-spec format_error(term()) -> io_lib:chars().
format_error(Reason) ->
  case Reason of
    {unsupported_entry_point, PC} ->
      io_lib:format("unsupported entry point ~4.16.0B", [PC]);
    {invalid_phdr, PhdrIx} ->
      io_lib:format("Phdr nr ~p is invalid", [PhdrIx]);
    {wrong_ei_mag, Mag} ->
      io_lib:format("Not ELF magic: ~p", [Mag]);
    {wrong_ei_class, Class} ->
      io_lib:format("wrong ei_class ~p", [Class]);
    {wrong_ei_data, Data} ->
      io_lib:format("wrong ei_data ~p", [Data]);
    {wrong_ei_version, Version} ->
      io_lib:format("wrong ei_version ~p", [Version]);
    {wrong_ei_osabi, OSABI} ->
      io_lib:format("wrong ei_osabi ~p", [OSABI]);
    {wrong_ei_abiversion, ABIVersion} ->
      io_lib:format("wrong ei_abiversion ~p", [ABIVersion]);
    {wrong_ei_pad, Pad} ->
      io_lib:format("wrong ei_pad ~p", [Pad]);
    {wrong_e_type, Type} ->
      io_lib:format("wrong e_type ~p", [Type]);
    {wrong_e_machine, Machine} ->
      io_lib:format("wrong e_machine ~p", [Machine]);
    {wrong_e_version, Version} ->
      io_lib:format("wrong e_version ~p", [Version]);
    {wrong_e_ehsize, EhSize} ->
      io_lib:format("wrong e_ehsize ~p", [EhSize]);
    {wrong_e_phentsize, PhEntSize} ->
      io_lib:format("wrong e_phentsize ~p", [PhEntSize]);
    {wrong_e_shentsize, ShEntSize} ->
      io_lib:format("wrong e_shentsize ~p", [ShEntSize]);
    {wrong_strtab_sh_type, ShType, Index} ->
      io_lib:format("wrong sh_type ~p for string table at index ~p",
                    [ShType, Index]);
    {wrong_strtab_index, Index} ->
      io_lib:format("out of range index ~p for string table", [Index]);
    {wrong_symtab_sh_entsize, ShEntSize} ->
      io_lib:format("wrong sh_entsize ~p in symtab section header", [ShEntSize]);
    {wrong_symtab_sh_size, ShSize} ->
      io_lib:format("wrong sh_size ~p in symtab section header", [ShSize]);
    eof ->
      "premature EOF";
    {wrong_index_in_strtab, Index} ->
      io_lib:format("out of range index ~p in string table", [Index]);
    strtab_not_nul_terminated ->
      "string table not NUL-terminated";
    program_too_large ->
      "program too large for 16-bit address space";
    _ ->
      io_lib:format("~p", [Reason])
  end.
