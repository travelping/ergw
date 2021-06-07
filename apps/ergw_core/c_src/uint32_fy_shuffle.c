/* Copyright 2021, Travelping GmbH <info@travelping.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */

/* Generate a sequence of at most 2^32 unsigned 32bit integers using the
 * Fisher-Yates shuffle */

#include <erl_nif.h>
#include <stdint.h>
#include <time.h>

#define STEPCNT (4*1024)

#define min(x,y) (				    \
    { __auto_type __x = (x); __auto_type __y = (y); \
      __x < __y ? __x : __y; })

static ERL_NIF_TERM
mk_atom(ErlNifEnv* env, const char* atom)
{
    ERL_NIF_TERM ret;

    if(!enif_make_existing_atom(env, atom, &ret, ERL_NIF_LATIN1))
    {
	return enif_make_atom(env, atom);
    }

    return ret;
}

static void swap (unsigned int *a, unsigned int *b)
{
    unsigned int temp = *a;
    *a = *b;
    *b = temp;
}

static ERL_NIF_TERM shuffle_ret(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM new_argv[4];
    ERL_NIF_TERM head, tail;
    unsigned int i, n, end;
    unsigned int *arr;
    ErlNifBinary bin;

    if (argc != 4 ||
	!enif_get_uint(env, argv[0], &n) || n <= 0 ||
	!enif_get_uint(env, argv[1], &i) || i > n ||
	!enif_inspect_binary(env, argv[2], &bin) ||
	!enif_is_list(env, argv[3]))
	return enif_make_badarg(env);

    /* printf("ret i: %u\n\r", i); */
    /* printf("ret n: %u\n\r", n); */

    tail = argv[3];
    end = min(n, i + STEPCNT);
    arr = (unsigned int *)bin.data;

    for (; i < end; i++) {
	head = enif_make_tuple1(env,
				enif_make_tuple2(env,
						 enif_make_int64(env, INT64_MIN + i),
						 enif_make_uint(env, arr[i])));
	tail = enif_make_list_cell(env, head, tail);
    }

    if (i >= n) {
	enif_release_binary(&bin);
	return tail;
    } else {
	new_argv[0] = argv[0];
	new_argv[1] = enif_make_uint(env, i);
	new_argv[2] = argv[2];
	new_argv[3] = tail;
	return enif_schedule_nif(env, "shuffle_ret", 0, shuffle_ret, 4, new_argv);
    }
}

static ERL_NIF_TERM shuffle_randomize(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM new_argv[4];
    unsigned int i, n, end;
    unsigned int *arr;
    ErlNifBinary bin;

    if (argc != 3 ||
	!enif_get_uint(env, argv[0], &n) || n <= 0 ||
	!enif_get_uint(env, argv[1], &i) || i > n ||
	!enif_inspect_binary(env, argv[2], &bin))
	return enif_make_badarg(env);

    if (i == n - 1)
	srand(time(NULL));

    end = (i > STEPCNT) ? i - STEPCNT : 0;
    arr = (unsigned int *)bin.data;

    for (; i > end; i--) {
	unsigned int j = rand() % (i+1);
	swap(&arr[i], &arr[j]);
    }

    new_argv[0] = argv[0];
    new_argv[2] = argv[2];

    if (i == 0) {
	new_argv[1] = enif_make_uint(env, 0);
	new_argv[3] = enif_make_list(env, 0);
	return enif_schedule_nif(env, "shuffle_ret", 0, shuffle_ret, 4, new_argv);
    } else {
	new_argv[1] = enif_make_uint(env, i);
	return enif_schedule_nif(env, "shuffle_randomize", 0, shuffle_randomize, 3, new_argv);
    }
}

static ERL_NIF_TERM shuffle_fill(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM new_argv[3];
    unsigned int i, n, end;
    unsigned int *arr;
    ErlNifBinary bin;

    if (argc != 3 ||
	!enif_get_uint(env, argv[0], &n) || n <= 0 ||
	!enif_get_uint(env, argv[1], &i) || i > n ||
	!enif_inspect_binary(env, argv[2], &bin))
	return enif_make_badarg(env);

    /* printf("fill i: %u\r\n", i); */
    /* printf("fill n: %u\r\n", n); */

    end = min(n, i + STEPCNT);
    arr = (unsigned int *)bin.data;

    for (; i < end; i++)
	arr[i] = i;

    new_argv[0] = argv[0];
    new_argv[2] = argv[2];

    if (i == n) {
	new_argv[1] = enif_make_uint(env, n - 1);
	return enif_schedule_nif(env, "shuffle_randomize", 0, shuffle_randomize, 3, new_argv);
    } else {
	new_argv[1] = enif_make_uint(env, i);
	return enif_schedule_nif(env, "shuffle_fill", 0, shuffle_fill, 3, new_argv);
    }
}

static ERL_NIF_TERM shuffle(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM new_argv[3];
    unsigned int n;

    if (!enif_get_uint(env, argv[0], &n) || n <= 0)
	return enif_make_badarg(env);

    if (!(enif_make_new_binary(env, n * sizeof(unsigned int), &new_argv[2])))
	return enif_raise_exception(env, mk_atom(env, "out_of_memory"));

    new_argv[0] = argv[0];
    new_argv[1] = enif_make_uint(env, 0);
    return enif_schedule_nif(env, "shuffle_fill", 0, shuffle_fill, 3, new_argv);
}

#if 0
static ERL_NIF_TERM shuffle(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM head, tail;
    unsigned int *arr;
    unsigned int i, n;

    if (!enif_get_uint(env, argv[0], &n) || n <= 0)
	return enif_make_badarg(env);

    if (!(arr = enif_alloc(n * sizeof(arr[0]))))
	return enif_raise_exception(env, mk_atom(env, "out_of_memory"));

    for (i = 0; i < n; i++)
	arr[i] = i;
    //randomize(arr, n);

    tail = enif_make_list(env, 0);
    for (i = 0; i < n; i++) {
	head = enif_make_uint(env, arr[i]);
	tail = enif_make_list_cell(env, head, tail);
    }
    return tail;
}
#endif

static ErlNifFunc nif_funcs[] =
{
	{"shuffle", 1, shuffle}
};

ERL_NIF_INIT(uint32_fy_shuffle, nif_funcs, NULL, NULL, NULL, NULL)
