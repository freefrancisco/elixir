%% Convenience functions used around elixir source code
%% to generate erlang abstract format for basic structures
%% as binaries, lists, condition clauses, etc.

-module(elixir_tree_helpers).
-compile({parse_transform, elixir_transform}).
-export([abstract_syntax/1, split_last/1, cons_to_list/1,
  convert_to_boolean/4, returns_boolean/1,
  build_bitstr/4, build_list/4, build_list/5, build_simple_list/2,
  build_reverse_list/4, build_reverse_list/5, build_simple_reverse_list/2]).
-include("elixir.hrl").

split_last([])         -> { [], [] };
split_last(List)       -> split_last(List, []).
split_last([H], Acc)   -> { lists:reverse(Acc), H };
split_last([H|T], Acc) -> split_last(T, [H|Acc]).

abstract_syntax(Tree) ->
  erl_syntax:revert(erl_syntax:abstract(Tree)).

cons_to_list({ cons, _, Left, { nil, _ } }) ->
  [Left];

cons_to_list({ cons, _, Left, Right }) ->
  [Left|cons_to_list(Right)].

% Build a list translating each expression and accumulating
% vars in one pass. It uses tail-recursive form.
%
% It receives a function to translate each expression given
% in Exprs, a Line used to build the List and the variables
% scope V is passed down item by item.
%
% The function needs to return a tuple where the first element
% is an erlang abstract form and the second is the new variables
% list.
build_list(Fun, Exprs, Line, S) ->
  build_list(Fun, Exprs, Line, S, {nil, Line}).

build_list(Fun, Exprs, Line, S, Tail) ->
  build_list_each(Fun, lists:reverse(Exprs), Line, S, Tail).

% Same as build_list, but the list given is in reverse other.
build_reverse_list(Fun, Exprs, Line, S) ->
  build_list_each(Fun, Exprs, Line, S, {nil,Line}).

build_reverse_list(Fun, Exprs, Line, S, Tail) ->
  build_list_each(Fun, Exprs, Line, S, Tail).

% Builds a simple list, without translatation, just by generating the cons-cell.
build_simple_list(Line, Args) ->
  { List, [] } = build_list(fun(X,Y) -> {X,Y} end, Args, Line, []),
  List.

build_simple_reverse_list(Line, Args) ->
  { List, [] } = build_reverse_list(fun(X,Y) -> {X,Y} end, Args, Line, []),
  List.

build_list_each(_Fun, [], _Line, S, Acc) ->
  { Acc, S };

build_list_each(Fun, [H|T], Line, S, Acc) ->
  { Expr, NS } = Fun(H, S),
  build_list_each(Fun, T, Line, NS, { cons, Line, Expr, Acc }).

% Build a bitstring taking into accounts the following types:
%
% * If a bitstring or a list is given, we just append its items
% * If '|' is given, extract the bitstring information
% * All the other types are simply translated and handled with Erlang's default
%
build_bitstr(Fun, Exprs, Line, S) ->
  { Final, FinalS } = build_bitstr_each(Fun, Exprs, Line, S, []),
  { { bin, Line, lists:reverse(Final) }, FinalS }.

build_bitstr_each(_Fun, [], _Line, S, Acc) ->
  { Acc, S };

build_bitstr_each(Fun, [H|T], Line, S, Acc) when is_list(H) ->
  { NewAcc, NewS } = build_bitstr_each(Fun, H, Line, S, Acc),
  build_bitstr_each(Fun, T, Line, NewS, NewAcc);

build_bitstr_each(Fun, [H|T], Line, S, Acc) when is_bitstring(H) ->
  { bin, _, Elements } = abstract_syntax(H),
  NewAcc = lists:foldl(fun(Element, FinalAcc) -> [Element|FinalAcc] end, Acc, Elements),
  build_bitstr_each(Fun, T, Line, S, NewAcc);

build_bitstr_each(Fun, [{'::',_,[H,V]}|T], Line, S, Acc) ->
  { Expr, NS } = Fun(H, S),

  %% Variables defined outside the binary can be accounted
  %% on subparts, however we can't assign new variables.
  case NS of
    { ES, _ } -> [];                       %% translate_arg,  no assigns
    _ -> ES = NS#elixir_scope{context=nil} %% translate_each, revert assigns
  end,

  { Size, Types } = extract_bit_values(Line, V, ES),
  build_bitstr_each(Fun, T, Line, NS, [{ bin_element, Line, Expr, Size, Types }|Acc]);

%% Deprecated syntax
build_bitstr_each(Fun, [{'|',_,[H,V]}|T], Line, S, Acc) ->
  { Expr, NS } = Fun(H, S),

  %% Just variables defined outside the binary can be accounted on subparts
  case NS of
    { ES, _ } -> [];
    ES -> []
  end,

  elixir_errors:deprecation(Line, ES#elixir_scope.file, "Old bitstring syntax with | is deprecated, use the new one with :: instead"),

  %% Assigns can be made in subparts
  { Int, Types } = extract_bin_values(Line, V, default, [], ES#elixir_scope{context=nil}),

  Final = case Types of
    [] -> default;
    _  -> lists:reverse(Types)
  end,

  build_bitstr_each(Fun, T, Line, NS, [{ bin_element, Line, Expr, Int, Final }|Acc]);

build_bitstr_each(Fun, [H|T], Line, S, Acc) ->
  { Expr, NS } = Fun(H, S),
  build_bitstr_each(Fun, T, Line, NS, [{ bin_element, Line, Expr, default, default }|Acc]).

%% Extra bitstring specifiers

extract_bit_values(Line, V, S) when is_list(V) ->
  extract_bit_values(Line, V, default, [], S);

extract_bit_values(Line, V, S) ->
  extract_bit_values(Line, [V], S).

extract_bit_values(Line, [{ Value, _CallLine, Atom }|T] = All, Size, Types, S)
    when is_atom(Value) andalso (is_atom(Atom) orelse Atom == []) ->
  case extract_bit_type(Value, Types) of
    { error, unknown } ->
      handle_unknown_specifier(Line, All, Size, Types, S);
    NewTypes when is_list(NewTypes) ->
      extract_bit_values(Line, T, Size, NewTypes, S)
  end;

extract_bit_values(Line, [{ Value, CallLine, [_] = Args }|T] = All, Size, Types, S) when is_atom(Value) ->
  { TArgs, _ } = elixir_translator:translate_args(Args, S),
  case extract_bit_type_or_size(Value, TArgs, Size, Types) of
    { error, unknown } ->
      handle_unknown_specifier(Line, All, Size, Types, S);
    { error, Msg } ->
      elixir_errors:syntax_error(CallLine, S#elixir_scope.file, Msg);
    { NewSize, NewTypes } ->
      extract_bit_values(Line, T, NewSize, NewTypes, S)
  end;

extract_bit_values(Line, [{ '|', _, [Left, Right] }], Size, Types, S) ->
  Expanded = 'Elixir.Macro':expand(Right, elixir_scope:to_ex_env({ Line, S })),
  extract_bit_values(Line, [Left|join_expansion(Expanded,[])], Size, Types, S);

extract_bit_values(Line, [_|_] = All, Size, Types, S) ->
  handle_unknown_specifier(Line, All, Size, Types, S);

extract_bit_values(_Line, [], Size, [], _S) ->
  { Size, default };

extract_bit_values(_Line, [], Size, Types, _S) ->
  { Size, lists:reverse(Types) }.

extract_bit_type(Value, Types) when
    Value == binary; Value == integer; Value == float; Value == bitstring;
    Value == signed; Value == unsigned;
    Value == big; Value == little; Value == native ->
  [Value|Types];

extract_bit_type(_Value, _Types) ->
  { error, unknown }.

extract_bit_type_or_size(size, [{ Kind, _, _ } = Arg], default, Types) when Kind == var; Kind == integer ->
  { Arg, Types };

extract_bit_type_or_size(size, _Args, default, _Types) ->
  { error, "size in bitstring expects an integer or a variable as argument" };

extract_bit_type_or_size(size, _Args, _Other, _Types) ->
  { error, "duplicated size definition for bitstring" };

extract_bit_type_or_size(unit, [{ integer, _, Arg }], Size, Types) ->
  { Size, [{ unit, Arg }|Types] };

extract_bit_type_or_size(unit, _Args, _Other, _Types) ->
  { error, "unit in bitstring expects an integer as argument" };

extract_bit_type_or_size(_Value, _Args, _Other, _Types) ->
  { error, unknown }.

handle_unknown_specifier(Line, [H|T], Size, Types, S) ->
  case 'Elixir.Macro':expand(H, elixir_scope:to_ex_env({ Line, S })) of
    H ->
      elixir_errors:syntax_error(Line, S#elixir_scope.file, "unknown bitstring specifier ~s", ['Elixir.Macro':to_binary(H)]);
    E ->
      extract_bit_values(Line, join_expansion(E,T), Size, Types, S)
  end.

join_expansion({ '__block__', _, [Expanded] }, Tail) -> join_expansion(Expanded, Tail);
join_expansion(Expanded, Tail) when is_list(Expanded) -> Expanded ++ Tail;
join_expansion(Expanded, Tail) -> [Expanded|Tail].

%% Deprecated specifiers

extract_bin_values(Line, { '-', _Line, [Left, Right] }, Int, Types, S) ->
  { LInt, LTypes } = extract_bin_values(Line, Left, Int, Types, S),
  extract_bin_values(Line, Right, LInt, LTypes, S);

extract_bin_values(Line, Value, default, Types, _S) when is_integer(Value) ->
  { { integer, Line, Value }, Types };

extract_bin_values(_Line, { Value, _, Atom } = Expr, default, Types, S) when is_atom(Value), is_atom(Atom) ->
  Translated = element(1, elixir_translator:translate_each(Expr, S)),
  { Translated, Types };

extract_bin_values(Line, Value, _Int, _Types, S) when is_integer(Value) ->
  elixir_errors:syntax_error(Line, S#elixir_scope.file, "duplicated size specifier ~p in <<>>", [Value]);

extract_bin_values(_Line, Value, Int, Types, _S) when is_atom(Value); is_tuple(Value), tuple_size(Value) == 2 ->
  { Int, [Value|Types] };

extract_bin_values(Line, _Value, _Int, _Types, S) ->
  elixir_errors:syntax_error(Line, S#elixir_scope.file, "invalid specifier for <<>>").

%% Others

returns_boolean({ op, _, Op, _ }) when Op == 'not' -> true;

returns_boolean({ op, _, Op, _, _ }) when
  Op == 'and'; Op == 'or'; Op == 'xor';
  Op == '==';  Op == '/='; Op == '=<';  Op == '>=';
  Op == '<';   Op == '>';  Op == '=:='; Op == '=/=' -> true;

returns_boolean({ op, _, Op, _, Right }) when Op == 'andalso'; Op == 'orelse' ->
  returns_boolean(Right);

returns_boolean({ call, _, { remote, _, { atom, _, erlang }, { atom, _, Fun } }, [_] }) when
  Fun == is_atom;   Fun == is_binary;   Fun == is_bitstring; Fun == is_boolean;
  Fun == is_float;  Fun == is_function; Fun == is_integer;   Fun == is_list;
  Fun == is_number; Fun == is_pid;      Fun == is_port;      Fun == is_reference;
  Fun == is_tuple -> true;

returns_boolean({ call, _, { remote, _, { atom, _, erlang }, { atom, _, Fun } }, [_,_] }) when
  Fun == is_function -> true;

returns_boolean(_) -> false.

convert_to_boolean(Line, Expr, Bool, InGuard) ->
  case { returns_boolean(Expr), Bool } of
    { true, true }  -> Expr;
    { true, false } -> { op, Line, 'not', Expr };
    _               -> do_convert_to_boolean(Line, Expr, Bool, InGuard)
  end.

do_convert_to_boolean(Line, Expr, Bool, false) ->
  Any   = [{var, Line, '_'}],
  False = [{atom,Line,false}],
  Nil   = [{atom,Line,nil}],

  FalseResult = [{atom,Line,not Bool}],
  TrueResult  = [{atom,Line,Bool}],

  { 'case', Line, Expr, [
    { clause, Line, False, [], FalseResult },
    { clause, Line, Nil, [], FalseResult },
    { clause, Line, Any, [], TrueResult }
  ] };

do_convert_to_boolean(Line, Expr, true, true) ->
  do_guarded_convert_to_boolean(Line, Expr, 'andalso', '/=');

do_convert_to_boolean(Line, Expr, false, true) ->
  do_guarded_convert_to_boolean(Line, Expr, 'orelse', '==').

do_guarded_convert_to_boolean(Line, Expr, Op, Comp) ->
  Left  = { op, Line, Comp, Expr, { atom, Line, false } },
  Right = { op, Line, Comp, Expr, { atom, Line, nil } },
  { op, Line, Op, Left, Right }.