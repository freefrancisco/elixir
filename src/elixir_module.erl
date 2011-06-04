-module(elixir_module).
-export([scope_for/2, transform/6, compile/7]).
-include("elixir.hrl").

%% EXTERNAL API

%% TEMPLATE BUILDING FOR MODULE COMPILATION

bootstrap_modules('Module::Definition') -> true;
bootstrap_modules('Module::Behavior')   -> true;
bootstrap_modules('Module::Using')      -> true;
bootstrap_modules(_)                    -> false.

% Build a template of an object or module used on compilation.
build_template(Kind, Name, Template) ->
  Mixins = default_mixins(Name),
  Data   = default_data(Template),

  AttributeTable = ?ELIXIR_ATOM_CONCAT([aex_, Name]),
  ets:new(AttributeTable, [set, named_table, private]),

  ets:insert(AttributeTable, { mixins, Mixins }),
  ets:insert(AttributeTable, { data,   Data }),

  Object = #elixir_module__{name=Name, data=AttributeTable},
  { Object, AttributeTable, { Mixins, [] } }.

% Default mixins based on the declaration type.
default_mixins(Name) ->
  case bootstrap_modules(Name) of
    true  -> [];
    false -> ['Module::Using', 'Module::Behavior']
  end.

% Returns the default data from parents.
default_data([])       -> orddict:new();
default_data(Template) -> Template#elixir_module__.data.

%% USED ON TRANSFORMATION AND MODULE COMPILATION

% Returns the new module name based on the previous scope.
scope_for([], Name) -> Name;
scope_for(Scope, Name) -> ?ELIXIR_ATOM_CONCAT([Scope, "::", Name]).

% Generates module transform. It wraps the module definition into
% a function that will be invoked by compile/7 passing self as argument.
% We need to wrap them into anonymous functions so nested module
% definitions have the variable self shadowed.
transform(Kind, Line, Name, Parent, Body, S) ->
  Filename = S#elixir_scope.filename,
  Clause = { clause, Line, [{var, Line, self}], [], Body },
  Fun = { 'fun', Line, { clauses, [Clause] } },
  Args = [{atom, Line, Kind}, {integer, Line, Line}, {string, Line, Filename},
    {var, Line, self}, {atom, Line, Name}, {atom, Line, Parent}, Fun],
  ?ELIXIR_WRAP_CALL(Line, ?MODULE, compile, Args).

% Initial step of template compilation. Generate a method
% table and pass it forward to the next compile method.
compile(Kind, Line, Filename, Current, Name, Template, Fun) ->
  MethodTable = elixir_def_method:new_method_table(Name),

  try
    compile(Kind, Line, Filename, Current, Name, Template, Fun, MethodTable)
  catch
    Type:Reason -> clean_up_tables(Type, Reason)
  end.

% Receive the module function to be invoked, invoke it passing
% self and then compile the added methods into an Erlang module
% and loaded it in the VM.
compile(Kind, Line, Filename, Current, Name, Template, Fun, MethodTable) ->
  { Object, AttributeTable, Extra } = build_template(Kind, Name, Template),

  try
    Result = Fun(Object),

    try
      ErrorInfo = elixir_constants:lookup(Name, attributes),
      [{ErrorFile,ErrorLine}] = proplists:get_value(exfile, ErrorInfo),
      error({objectdefined, {Name, list_to_binary(ErrorFile), ErrorLine}})
    catch
      error:{noconstant, _} -> []
    end,

    compile_kind(Kind, Line, Filename, Current, Object, Extra, MethodTable),
    Result
  catch
    Type:Reason -> clean_up_tables(Type, Reason)
  end.

% Handle compilation logic specific to objects or modules.
compile_kind(module, Line, Filename, Current, Module, _, MethodTable) ->
  Name = Module#elixir_module__.name,

  % Update mixins to have the module itself
  AttributeTable = Module#elixir_module__.data,
  Mixins = ets:lookup_element(AttributeTable, mixins, 2),
  ets:insert(AttributeTable, { mixins, [Name|Mixins] }),

  case bootstrap_modules(Name) of
    true  -> [];
    false -> elixir_def_method:flat_module(Module, Line, mixins, Module, MethodTable)
  end,
  compile_module(Line, Filename, Module, MethodTable).

% Handle logic compilation. Called by both compile_kind(module) and compile_kind(object).
% The latter uses it for implicit modules.
compile_module(Line, Filename, Module, MethodTable) ->
  Functions = elixir_def_method:unwrap_stored_methods(MethodTable),
  load_form(build_module_form(Line, Filename, Module, Functions), Filename),
  ets:delete(Module#elixir_module__.data),
  ets:delete(MethodTable).

% Build a module form. The difference to an object form is that we need
% to consider method related attributes for modules.
% TODO: Cache __module_name__, exported functions and snapshot
build_module_form(Line, Filename, Object, {Public, Inherited, F0}) ->
  E0 = Public ++ Inherited,

  { E1, F1 } = add_extra_function(E0, F0, {'__mixins__',1},          mixins_function(Line, Object)),
  { E2, F2 } = add_extra_function(E1, F1, {'__elixir_exported__',2}, exported_function(Line, Object)),
  { E3, F3 } = add_extra_function(E2, F2, {'__module_name__',1},     module_name_function(Line, Object)),
  { E4, F4 } = add_extra_function(E3, F3, {'__module__',1},          module_function(Line, Object)),

  Extra = [
    {attribute, Line, public, Public},
    {attribute, Line, compile, no_auto_import()},
    {attribute, Line, export, E4} | F4
  ],

  build_erlang_form(Line, Filename, Object, Extra).

add_extra_function(Exported, Functions, Pair, Contents) ->
  case lists:member(Pair, Exported) of
    true  -> { Exported, Functions };
    false -> { [Pair|Exported], [Contents|Functions] }
  end.

module_function(Line, #elixir_module__{name=Name, data=AttributeTable}) ->
  Data = ets:lookup_element(AttributeTable, data, 2),
  Snapshot = #elixir_module__{name=?ELIXIR_ERL_MODULE(Name), data=Data},
  Reverse = elixir_tree_helpers:abstract_syntax(Snapshot),
  { function, Line, '__module__', 1,
    [{ clause, Line, [{var,Line,'_'}], [], [Reverse]}]
  }.

mixins_function(Line, Object) ->
  % TODO: Make using a feature of the language
  Mixins = lists:delete('Module::Using', destructive_read(Object#elixir_module__.data, mixins)),
  { MixinsTree, [] } = elixir_tree_helpers:build_list(fun(X,Y) -> {{atom,Line,X},Y} end, Mixins, Line, []),
  { function, Line, '__mixins__', 1,
    [{ clause, Line, [{var,Line,'_'}], [], [MixinsTree]}]
  }.

module_name_function(Line, Object) ->
  { function, Line, '__module_name__', 1,
    [{ clause, Line, [{var,Line,'_'}], [], [{atom,Line,?ELIXIR_EX_MODULE(Object#elixir_module__.name)}]}]
  }.

build_erlang_form(Line, Filename, Object, Extra) ->
  Name = Object#elixir_module__.name,
  AttributeTable = Object#elixir_module__.data,
  Data = destructive_read(AttributeTable, data),

  % TODO Analyze all the attributes being passed.
  Transform = fun(X, Acc) -> [transform_attribute(Line, X)|Acc] end,
  ModuleName = ?ELIXIR_ERL_MODULE(Name),
  Base = ets:foldr(Transform, Extra, AttributeTable),

  [{attribute, Line, module, ModuleName}, 
   {attribute, Line, file, {Filename,Line}}, {attribute, Line, exfile, {Filename,Line}}| Base].

% Compile and load given forms as an Erlang module.
load_form(Forms, Filename) ->
  case compile:forms(Forms, [return]) of
    {ok, ModuleName, Binary, Warnings} ->
      case get(elixir_compiled) of
        Current when is_list(Current) ->
          put(elixir_compiled, [{ModuleName,Binary}|Current]);
        _ ->
          []
      end,
      format_warnings(Filename, Warnings),
      code:load_binary(ModuleName, Filename, Binary);
    {error, Errors, Warnings} ->
      format_warnings(Filename, Warnings),
      format_errors(Filename, Errors)
  end.

%% BUILD AND LOAD HELPERS

destructive_read(Table, Attribute) ->
  Value = ets:lookup_element(Table, Attribute, 2),
  ets:delete(Table, Attribute),
  Value.

no_auto_import() ->
  {no_auto_import, [
    {size, 1}, {length, 1}, {error, 2}, {self, 1}, {put, 2},
    {get, 1}, {exit, 1}, {exit, 2}
  ]}.

transform_attribute(Line, X) ->
  {attribute, Line, element(1, X), element(2, X)}.

exported_function(Line, Object) ->
  { function, Line, '__elixir_exported__', 2,
    [{ clause, Line, [{var,Line,function},{var,Line,arity}], [], [
      ?ELIXIR_WRAP_CALL(
        Line, erlang, function_exported,
        [{atom,Line,?ELIXIR_ERL_MODULE(Object#elixir_module__.name)},{var,Line,function},{var,Line,arity}]
      )
    ]}]
  }.

format_errors(Filename, []) ->
  exit({nocompile, "compilation failed but no error was raised"});

format_errors(Filename, Errors) ->
  lists:foreach(fun ({_, Each}) ->
    lists:foreach(fun (Error) -> elixir_errors:handle_file_error(Filename, Error) end, Each)
  end, Errors).

format_warnings(Filename, Warnings) ->
  lists:foreach(fun ({_, Each}) ->
    lists:foreach(fun (Warning) -> elixir_errors:handle_file_warning(Filename, Warning) end, Each)
  end, Warnings).

clean_up_tables(Type, Reason) ->
  ElixirTables = [atom_to_list(X) || X <- ets:all(), is_atom(X)],
  lists:foreach(fun clean_up_table/1, ElixirTables),
  erlang:Type(Reason).

clean_up_table("aex_" ++ _ = X) ->
  ets:delete(list_to_atom(X));

clean_up_table("mex_" ++ _ = X) ->
  ets:delete(list_to_atom(X));

clean_up_table(_) -> [].