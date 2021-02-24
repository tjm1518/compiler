-module(build_ir).
-export([process/1]).

process(Ast) ->
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
  {A_Context,_} = lists:foldl(fun
    (Arg, {N_Context,St}) ->
      {ok, N2_Context, N_St} = process(Arg, N_Context),
      {N2_Context, St++N_St}
  end, {Context,[]}, Args),
  {ok,_N_Context,N_St} = process(Statement, [{function,{Ident,{Type,length(Args)}}} | A_Context]),
  {ok,[{function,{Ident,{Type,length(Args)}}}|Context],[{function, Type, Ident, length(Args),N_St}]};
% TODO: Implement any other fn types
process({function, Fn_Spec}, _Context) ->
  error({unknown_fn_spec,Fn_Spec});

%% Declarations
process({declaration, O_Type, O_Specs}, Context) ->
  {ok,Ident,St} = get_decl_specs(O_Specs),
  {ok,_N_Context,N_St} = process(St,Context),
  Type = check_typedef(O_Type, Context),
  Rv_Cnt = proplists:get_value(rvcnt, Context),
  N_Context = [{variable,{Ident,{Type,{y,Rv_Cnt}}}} | increment(rvcnt, Context)],
  Lv_Cnt = proplists:get_value(lvcnt,N_Context),
  if
    N_St =:= [] -> {ok,N_Context,[]};
    true -> {ok,N_Context,N_St ++ [{move,{x,Lv_Cnt},{y,Rv_Cnt}}]}
  end;

process({assign, {'=',Ln}, O_Specs}, Context) ->
  {ok,Ident,St} = get_decl_specs(O_Specs),
  {ok,_N_Context,N_St} = process(St,Context),
  Variables = proplists:get_all_values(variable, Context),
  case proplists:get_value(Ident, Variables) of
    {_Type, X} ->
      Lv_Cnt = proplists:get_value(lvcnt,Context),
      {ok,Context,N_St++[{move,{x,Lv_Cnt},X}]};
    Other -> error({Other,Ident,{line,Ln},{context,Context}})
  end;

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
  {ok,increment(lvcnt,Context),[{move,{integer,Val},{x,V_Cnt}}]};

%% Identifiers
process({identifier,Ln,Ident}, Context) ->
  Variables = proplists:get_all_values(variable, Context),
  case proplists:get_value(Ident, Variables) of
    {_Type, X} ->
      V_Cnt = proplists:get_value(lvcnt,Context),
      {ok,increment(lvcnt,Context),[{move,X,{x,V_Cnt}}]};
    Other -> error({Other, Ident, {line, Ln}, {context, Context}})
  end;

% TODO: Process args
process({{identifier,Ln,Ident},{apply,Args}}, Context) ->
  {_, P_Args} = lists:foldl(fun
    (Arg, {N_Context, St}) ->
      {ok, N2_Context, N_St} = process(Arg, N_Context),
      {N2_Context, St ++ N_St}
  end, {Context, []}, Args),
  Functions = proplists:get_all_values(function, Context),
  case proplists:get_value(Ident, Functions) of
    {_Type, Len} when Len =:= length(Args) ->
      {ok, Context, P_Args ++ [{call,Ident,Len,{x,proplists:get_value(lvcnt,Context)}}]};
    Other ->
      error({Other, Ident, {args, Args}, {line, Ln}, {context, Context}})
  end;

%% Jump Statements
% If
process({{'if',_},Test,True,False}, Context) ->
  {ok,If_Context,If_St} = process(Test, Context),
  Test_Eq = {test,{x,proplists:get_value(lvcnt, Context)},
                  {f,proplists:get_value(lbcnt, If_Context)+1}},
  {ok,T_Context,T_St} = process(True,replace(lbcnt,proplists:get_value(lbcnt,If_Context),Context)),
  Lb_Cnt = proplists:get_value(lbcnt, T_Context),
  Jump = {jump,{f,Lb_Cnt+2}},
  Start_Label = {label,Lb_Cnt+1},
  {ok,F_Context,F_St} = process(False, replace(lbcnt, Lb_Cnt+2, T_Context)),
  End_Label = {label,Lb_Cnt+2},
  {ok,F_Context,If_St++[Test_Eq|T_St]++[Jump,Start_Label|F_St]++[End_Label]};
% While
process({{'while',_},Test,Do}, Context) ->
  Lb_Cnt = proplists:get_value(lbcnt,Context),
  Start_Label = {label,Lb_Cnt+1},
  {ok,Pred_Context,Pred_St} = process(Test,replace(lbcnt, Lb_Cnt+2, Context)),
  Test_St = {test,{x,proplists:get_value(lvcnt, Context)},{f,Lb_Cnt+2}},
  {ok, Do_Context, Do_St} = process(Do, replace(lbcnt,proplists:get_value(lbcnt, Pred_Context),Context)),
  Jump = {jump,{f,Lb_Cnt+1}},
  End_Label = {label,Lb_Cnt+2},
  {ok,replace(lbcnt,proplists:get_value(lbcnt, Do_Context),Context),[Start_Label|Pred_St]++[Test_St|Do_St]++[Jump,End_Label]};
% Do While
process({{'do',_},Do,Test}, Context) ->
  Lb_Cnt = proplists:get_value(lbcnt,Context),
  Label = {label,Lb_Cnt+1},
  {ok,Do_Context,Do_St} = process(Do,increment(lbcnt,Context)),
  {ok,T_Context,Test_St} = process(Test,replace(lbcnt,proplists:get_value(lbcnt,Do_Context),Context)),
  Jump = {test,{x,proplists:get_value(lvcnt,Context)},{f,Lb_Cnt+1}},
  {ok,replace(lbcnt,proplists:get_value(lbcnt,T_Context),Context),[Label|Do_St]++Test_St++[Jump]};
% For
process({{for,_},{First,Pred,St},Loop},Context) ->
  Lb_Cnt = proplists:get_value(lbcnt, Context),
  Lv_Cnt = proplists:get_value(lvcnt,Context),
  {ok,F_Context,F_St} = process(First,replace(lbcnt,Lb_Cnt+3,Context)),
  P_Label = {label,Lb_Cnt+1},
  {ok,P_Context,P_St} = process(Pred,replace(lvcnt,Lv_Cnt,F_Context)),
  P_Test = {test,{x,proplists:get_value(lvcnt, F_Context)},{f,Lb_Cnt+2}},
  {ok,L_Context,L_St} = process(Loop,replace(lvcnt,Lv_Cnt,P_Context)),
  {ok,N_Context,N_St} = process(St,replace(lbcnt,proplists:get_value(lbcnt,L_Context),replace(lvcnt,Lv_Cnt,F_Context))),
  Jump = {jump, {f,Lb_Cnt+1}},
  E_Label = {label,Lb_Cnt+2},
  {ok,replace(lbcnt,proplists:get_value(lbcnt,N_Context),Context),F_St++[P_Label|P_St]++[P_Test|L_St++N_St]++[Jump,E_Label]};


%% Return
process({{return,_},Statement}, Context) ->
  {ok,_N_Context,N_St} = process(Statement, Context),
  {ok,Context,N_St++[return]};

%% Base Case
process(Part, Context) ->
  io:fwrite("Part:~n~p~n~n",[Part]),
  {ok,Context,[]}.

get_decl_specs([{identifier,_,Ident}]) ->
  {ok, Ident, []};
get_decl_specs([{{identifier,_,Ident},{'=',_},St}]) ->
  {ok, Ident, St};
get_decl_specs([{identifier,_,Ident},St]) ->
  {ok, Ident, St};
get_decl_specs(Unkn) ->
  io:fwrite("Unknown, ~p", [Unkn]),
  {ok,nil,[]}.



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

replace(Key, Value, List) ->
  [{Key, Value} | proplists:delete(Value, List)].

fun_2(Type,A,B,Context) ->
  {ok,A_Context,A_St} = process(A,Context),
  N_A_Context = replace(lvcnt,proplists:get_value(lvcnt,Context)+1,A_Context),
  {ok,B_Context,B_St} = process(B,N_A_Context),
  V_Cnt = proplists:get_value(lvcnt,Context),
  Statement = A_St ++ B_St ++ [{Type,{x,V_Cnt},[{x,V_Cnt},{x,V_Cnt+1}]}],
  {ok,B_Context,Statement}.