#include <erl_nif.h>
#include <vector>
#include <stdio.h>
#include "erl_translator.hpp"

static ERL_NIF_TERM translate(ErlNifEnv* Env, int Argc, const ERL_NIF_TERM Argv[]) {
  // Arity 1 function expects a single argument
  if (Argc != 1 || !enif_is_list(Env,Argv[0])) return enif_make_badarg(Env);
  auto Ir = ir::get_ir(Env, Argv[0]);
  printf("%d\n",Ir.size());

  return enif_make_atom(Env,"ok");
}

static ErlNifFunc nif_funcs[] = {
    {"translate", 1, translate}
};

ERL_NIF_INIT(ir2mips, nif_funcs, NULL, NULL, NULL, NULL);
