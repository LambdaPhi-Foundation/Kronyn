/* Kronyn C runtime (kronyn_rt.h) — shared library for -compile output.
 *
 * Ownership convention (the whole design hangs on this):
 *  - Every function returning KRN_Value* returns an OWNED reference
 *    (refcount >= 1, caller must krn_release it or store it).
 *  - Functions BORROW their KRN_Value* inputs: they never retain or
 *    release arguments. Transferring an input into the result (e.g.
 *    unwrapOr returning its default) is allowed and documented below.
 *  - krn_set retains the stored value; krn_get returns an owned ref.
 *  - The NONE singleton is immortal: retain/release skip it.
 * Values are immutable once built (every op allocates), so aliasing
 * (e.g. to_str on a string) is safe under refcounting.
 *
 * Errors: krn_fail prints "Kronyn error: ..." plus a capped traceback
 * to stdout (mirroring the interpreter driver) and exits 1. The
 * "current line" is set by emitted code via krn_line() before each
 * statement; it defaults to -1 (no prefix), exactly like kerr.
 */
#ifndef KRONYN_RT_H
#define KRONYN_RT_H

#include <setjmp.h>
#include <stddef.h>

typedef enum { KRN_INT, KRN_STR, KRN_LIST, KRN_SOME, KRN_NONE } KRN_Kind;

typedef struct KRN_Value KRN_Value;
struct KRN_Value {
  int rc;
  KRN_Kind kind;
  union {
    long long i;
    struct { char *data; size_t len; } s;
    struct { KRN_Value **items; size_t len; size_t cap; } l;
    KRN_Value *inner;
  } u;
};

typedef struct KRN_Env KRN_Env;

/* lifecycle */
void krn_init(int argc, char **argv);
KRN_Env *krn_new_env(KRN_Env *parent);
void krn_free_env(KRN_Env *env);
void krn_env_clear(KRN_Env *env); /* release locals, keep parent+capacity */
KRN_Value *krn_retain(KRN_Value *v);
void krn_release(KRN_Value *v);

/* constructors: all return OWNED refs */
KRN_Value *krn_int(long long i);
KRN_Value *krn_str(const char *data, size_t len);
KRN_Value *krn_str_c(const char *c);
KRN_Value *krn_none(void);
KRN_Value *krn_some(KRN_Value *inner); /* consumes inner */
KRN_Value *krn_list_new(void);
void krn_list_append(KRN_Value *list, KRN_Value *item); /* consumes item */

/* variables */
KRN_Value *krn_get(KRN_Env *env, const char *name); /* owned; "" if missing */
void krn_set(KRN_Env *env, const char *name, KRN_Value *v); /* retains */

/* coercion / truth (borrow input) */
KRN_Value *krn_to_str(KRN_Value *v); /* owned; aliases strings via retain */
const char *krn_kind_name(KRN_Value *v);
void krn_check_kind(KRN_Value *v, KRN_Kind want, const char *proc,
                    const char *param, int line);
void krn_check_return(KRN_Value *v, KRN_Kind want, const char *proc, int line);
void krn_fail_arity(const char *name, int line, int expected, int got);
void krn_warn_deprecated(const char *name, int line, const char *msg);
int krn_truthy(KRN_Value *v);
/* int-kind or all-digits string (mirrors tryWordInt: no whitespace) */
int krn_is_intval(KRN_Value *v, long long *out);
/* tolerant integer conversion (mirrors Nim parseInt); fails kind "error" */
long long krn_as_int(KRN_Value *v);

/* errors */
void krn_line(int line);
_Noreturn void krn_fail(const char *kind, int line, const char *msg);
void krn_push_frame(const char *name, int line);
void krn_pop_frame(void);

/* error recovery (try/retry): handlers stack; krn_fail longjmps to the
 * top instead of exiting while one is active. Handler structs live in
 * emitted frames (never copied); only pointers are stacked. */
typedef struct KRN_Handler KRN_Handler;
struct KRN_Handler {
  jmp_buf jb;
  unsigned long envSeq;
  size_t tmoDepth;
};
void krn_push_handler(KRN_Handler *h);
void krn_pop_handler(void);
_Noreturn void krn_rethrow(void); /* jump to the next handler or fatal */
const char *krn_err_kind(void);
const char *krn_err_msg(void);
int krn_err_line(void);
const char *krn_err_trace(void);

/* cooperative timeouts (wall clock). arm nests by minimum deadline;
 * checks belong at loop heads and proc entries (straight-line code is
 * finite, so it cannot diverge past a check). */
void krn_timeout_arm(const char *owner, int line, int ms);
void krn_timeout_pop(void);
void krn_check_timeout(void);

/* operators: borrow inputs, return owned */
KRN_Value *krn_add(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_sub(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_mul(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_divide(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_concat(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_eq(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_ne(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_lt(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_gt(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_lte(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_gte(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_kand(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_kor(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_knot(KRN_Value *a);

/* kernel builtins: borrow inputs, return owned (may transfer an input) */
KRN_Value *krn_b_writeln(KRN_Value *a);
KRN_Value *krn_b_write(KRN_Value *a);
KRN_Value *krn_b_input(void);
KRN_Value *krn_b_readln(void);
KRN_Value *krn_b_toUpper(KRN_Value *a);
KRN_Value *krn_b_toLower(KRN_Value *a);
KRN_Value *krn_b_len(KRN_Value *a);
KRN_Value *krn_b_trim(KRN_Value *a);
KRN_Value *krn_b_ascii(KRN_Value *a);
KRN_Value *krn_b_char(KRN_Value *a);
KRN_Value *krn_b_int(KRN_Value *a);
KRN_Value *krn_b_str(KRN_Value *a);
KRN_Value *krn_b_typeof(KRN_Value *a);
KRN_Value *krn_b_isInt(KRN_Value *a);
KRN_Value *krn_b_isString(KRN_Value *a);
KRN_Value *krn_b_isList(KRN_Value *a);
KRN_Value *krn_b_slice(KRN_Value *a, KRN_Value *b, KRN_Value *c);
KRN_Value *krn_b_index(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_b_contains(KRN_Value *a, KRN_Value *b); /* "true"/"false" strs */
KRN_Value *krn_b_replace(KRN_Value *a, KRN_Value *b, KRN_Value *c);
KRN_Value *krn_b_split(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_b_concat(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_b_mod(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_b_exec(KRN_Value *a);
KRN_Value *krn_b_lines(KRN_Value *a);
KRN_Value *krn_b_filter(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_b_count(KRN_Value *a);
KRN_Value *krn_b_first(KRN_Value *a);
KRN_Value *krn_b_last(KRN_Value *a);
KRN_Value *krn_b_some(KRN_Value *a); /* consumes a */
KRN_Value *krn_b_none(void);
KRN_Value *krn_b_somep(KRN_Value *a);
KRN_Value *krn_b_nonep(KRN_Value *a);
KRN_Value *krn_b_unwrap(KRN_Value *a); /* transfers inner */
KRN_Value *krn_b_unwrapOr(KRN_Value *a, KRN_Value *b); /* transfers one input */

/* syscalls (statement form takes already-evaluated owned args, like
 * everything else; all return owned values) */
KRN_Value *krn_sys_io_output(KRN_Value *a);
KRN_Value *krn_sys_io_outputln(KRN_Value *a);
KRN_Value *krn_sys_io_input(void);
KRN_Value *krn_sys_fs_read(KRN_Value *a);
KRN_Value *krn_sys_fs_write(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_sys_fs_exists(KRN_Value *a);
KRN_Value *krn_sys_fs_append(KRN_Value *a, KRN_Value *b);
KRN_Value *krn_sys_fs_remove(KRN_Value *a);
KRN_Value *krn_sys_fs_list(KRN_Value *a);
KRN_Value *krn_sys_proc_exit(int argc, KRN_Value **argv);
KRN_Value *krn_sys_proc_args(void);

#endif
