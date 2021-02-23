-module(var_rename).
-export([process/1]).

process(Ast) ->
  io:fwrite("Ast:~n~n~p~n~n", [Ast]),
  process(Ast, [{lbcnt,0},{lvcnt,0},{rvcnt,0}]).
process([], Context) -> {ok,Context,[]};
process([St|Ast], Context) ->
  {ok,N_Context,St_List} = process(St,Context),
  {ok,N2_Context,N_St_List} = process(Ast,N_Context),
  {ok,N2_Context,St_List++N_St_List};

%% Functions
% TODO: Work out if ANSI C has default args & implement this
process({function,{Return_Type,{{identifier,_,Ident},Args},Statement}},Context) ->
  Type = check_typedef(Return_Type, Context),
  {ok,N_Context,N_St} = process(Statement, [{function,{Ident,{Type,length(Args)}}}|Context]),
  {ok,N_Context,[{function, Type, Ident, length(Args), N_St}]};
process({function, Fn_Spec}, _Context) ->
  error({unknown_fn_spec,Fn_Spec});

%% Declarations
process({declaration, O_Type, O_Specs}, Context) ->
  {ok,Ident,N_St} = get_decl_specs(O_Specs, Context),
  Type = check_typedef(O_Type, Context),
  Rv_Cnt = proplists:get_value(rvcnt, Context),
  N_Context = [{variable,{Ident,{Type,{y,Rv_Cnt}}}} | increment(rvcnt, Context)],
  {ok,N_Context,N_St ++ [{move,{y,Rv_Cnt},{x,proplists:get_value(lvcnt,N_Context)}}]};

%% Built-in Functions (arity 2, eg a+b, a!=b, etc.)
process({bif,T,[A,B]}, Context) ->
  {Way_1,Way_2} = {fun_2(T,A,B,Context),fun_2(T,B,A,Context)},
  {Way_1_N,Way_2_N} = {proplists:get_value(lvcnt, element(2,Way_1)),
                       proplists:get_value(lvcnt, element(2,Way_2))},
  if
    Way_1_N > Way_2_N -> Way_2;
    true -> Way_1
  end;

%% Literal values
process({int_l,_,Val,_Suf}, Context) ->
  V_Cnt = proplists:get_value(lvcnt,Context),
  {ok,increment(lvcnt,Context),[{move,{x,V_Cnt},{integer,Val}}]};

%% Identifiers
process({identifier,Ln,Ident}, Context) ->
  Variables = proplists:get_all_values(variable, Context),
  case proplists:get_value(Ident, Variables) of
    {_Type, X} ->
      V_Cnt = proplists:get_value(lvcnt,Context),
      {ok,increment(lvcnt,Context),[{move,{x,V_Cnt},X}]};
    Other -> error({Other, Ident, {line, Ln}, {context, Context}})
  end;

% TODO: Process args
process({{identifier,Ln,Ident},{apply,Args}}, Context) ->
  Functions = proplists:get_all_values(function, Context),
  case proplists:get_value(Ident, Functions) of
    {Type, Len} when Len =:= length(Args) -> {ok, Context, [{call,Ident,Args}]};
    Other -> error({Other, Ident, {line, Ln}, {context, Context}})
  end;

%% Return
process({{return,_},Statement}, Context) ->
  {ok,_N_Context,N_St} = process(Statement, Context),
  {ok,Context,N_St};

%% Base Case
process(Part, Context) ->
  io:fwrite("Part:~n~p~n~n",[Part]),
  {ok,Context,[]}.

get_decl_specs([{identifier,_,Ident}],_Context) ->
  {ok, Ident, []};
get_decl_specs([{{identifier,_,Ident},{'=',_},St}],Context) ->
  {ok, _N_Context, N_St} = process(St,Context),
  {ok, Ident, N_St}.


check_typedef(Type, Context) ->
  Typedefs = proplists:get_all_values(typedef, Context),
  case proplists:get_value(Type, Typedefs) of
    undefined -> get_type(Type);
    Typedef -> get_type(Typedef)
  end.

get_type([{long,_},{long,_},{int,_}]) -> int64;
get_type([{long,_},{int,_}]) -> int64;
get_type([{int,_}]) -> int32;

get_type(Type) -> error({unknown_type, Type}).

increment(Key, List) ->
  Value = proplists:get_value(Key, List),
  [{Key,Value+1} | proplists:delete(Key,List)].

fun_2(Type,A,B,Context) ->
  {ok,A_Context,A_St} = process(A,Context),
  N_A_Context = [{lvcnt,proplists:get_value(lvcnt,Context)+1} | proplists:delete(lvcnt,A_Context)],
  {ok,B_Context,B_St} = process(B,N_A_Context),
  V_Cnt = proplists:get_value(lvcnt,Context),
  Statement = A_St ++ B_St ++ [{Type,{x,V_Cnt},[{x,V_Cnt},{x,V_Cnt+1}]}],
  {ok,B_Context,Statement}.
