/* Kronyn C runtime — implements kronyn_rt.h for -compile output.
 * Mirrors src/eval.nim semantics; deviations are noted in COMPILE.md.
 */
#include "kronyn_rt.h"

#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dirent.h>
#endif

/* forward: failure recovery frees abandoned envs (defined below) */
static void krn_free_env_contents(KRN_Env *env);

/* ---------- allocation ---------- */

static void *xmalloc(size_t n) {
  void *p = malloc(n ? n : 1);
  if (!p) {
    fprintf(stderr, "kronyn: out of memory\n");
    exit(2);
  }
  return p;
}

static void *xrealloc(void *p, size_t n) {
  void *q = realloc(p, n ? n : 1);
  if (!q) {
    fprintf(stderr, "kronyn: out of memory\n");
    exit(2);
  }
  return q;
}

static char *xstrndup(const char *s, size_t n) {
  char *p = xmalloc(n + 1);
  memcpy(p, s, n);
  p[n] = '\0';
  return p;
}

#ifdef KRN_LEAK_CHECK
/* Leak census: live Values (NONE singleton excluded by construction)
 * and envs. Reported at exit to stderr (stdout stays parity-clean).
 * Success exits must read 0/0; caught errors abandon their in-flight
 * heap by design (see COMPILE.md deviation 14). */
static long live_values = 0;
static long live_envs = 0;

static void krn_leak_report(void) {
  fprintf(stderr, "krn-leak-check: values=%ld envs=%ld\n", live_values,
          live_envs);
}
#endif

/* growable byte buffer */
typedef struct { char *data; size_t len, cap; } Buf;

static void bufInit(Buf *b) {
  b->cap = 64;
  b->len = 0;
  b->data = xmalloc(b->cap);
}

static void bufNeed(Buf *b, size_t extra) {
  while (b->len + extra > b->cap) {
    b->cap *= 2;
    b->data = xrealloc(b->data, b->cap);
  }
}

static void bufAdd(Buf *b, const char *s, size_t n) {
  bufNeed(b, n + 1);
  memcpy(b->data + b->len, s, n);
  b->len += n;
}

static void bufAddC(Buf *b, char c) {
  bufNeed(b, 2);
  b->data[b->len++] = c;
}

/* unbounded inputs (proc names, user values, paths) must never meet a
 * fixed buffer: dynamic printf used by every failure message. */
static char *msgf(const char *fmt, ...) {
  va_list ap, aq;
  int n;
  char *m;
  va_start(ap, fmt);
  va_copy(aq, ap);
  n = vsnprintf(NULL, 0, fmt, aq);
  va_end(aq);
  if (n < 0)
    n = 0;
  m = xmalloc((size_t)n + 1);
  vsnprintf(m, (size_t)n + 1, fmt, ap);
  va_end(ap);
  return m;
}

static void bufPrintf(Buf *b, const char *fmt, ...) {
  va_list ap, aq;
  int n;
  va_start(ap, fmt);
  va_copy(aq, ap);
  n = vsnprintf(NULL, 0, fmt, aq);
  va_end(aq);
  if (n < 0) {
    va_end(ap);
    return;
  }
  bufNeed(b, (size_t)n + 1);
  vsnprintf(b->data + b->len, (size_t)n + 1, fmt, ap);
  va_end(ap);
  b->len += (size_t)n;
}

/* ---------- values ---------- */

/* immortal NONE singleton (retain/release skip it) */
static KRN_Value none_singleton = {0, KRN_NONE, {0}};

KRN_Value *krn_retain(KRN_Value *v) {
  if (v && v->kind != KRN_NONE)
    v->rc++;
  return v;
}

void krn_release(KRN_Value *v) {
  size_t i;
  if (!v || v->kind == KRN_NONE)
    return;
  if (--v->rc > 0)
    return;
#ifdef KRN_LEAK_CHECK
  live_values--;
#endif
  switch (v->kind) {
  case KRN_STR:
    free(v->u.s.data);
    break;
  case KRN_LIST:
    for (i = 0; i < v->u.l.len; i++)
      krn_release(v->u.l.items[i]);
    free(v->u.l.items);
    break;
  case KRN_SOME:
    krn_release(v->u.inner);
    break;
  default:
    break;
  }
  free(v);
}

static KRN_Value *newVal(KRN_Kind k) {
  KRN_Value *v = xmalloc(sizeof *v);
  v->rc = 1;
  v->kind = k;
#ifdef KRN_LEAK_CHECK
  live_values++;
#endif
  return v;
}

KRN_Value *krn_int(long long i) {
  KRN_Value *v = newVal(KRN_INT);
  v->u.i = i;
  return v;
}

KRN_Value *krn_str(const char *data, size_t len) {
  KRN_Value *v = newVal(KRN_STR);
  v->u.s.data = xstrndup(data ? data : "", len);
  v->u.s.len = len;
  return v;
}

KRN_Value *krn_str_c(const char *c) {
  return krn_str(c ? c : "", c ? strlen(c) : 0);
}

KRN_Value *krn_none(void) { return &none_singleton; }

KRN_Value *krn_some(KRN_Value *inner) {
  KRN_Value *v = newVal(KRN_SOME);
  v->u.inner = inner ? inner : krn_none();
  return v;
}

KRN_Value *krn_list_new(void) {
  KRN_Value *v = newVal(KRN_LIST);
  v->u.l.items = NULL;
  v->u.l.len = 0;
  v->u.l.cap = 0;
  return v;
}

void krn_list_append(KRN_Value *list, KRN_Value *item) {
  if (list->u.l.len == list->u.l.cap) {
    list->u.l.cap = list->u.l.cap ? list->u.l.cap * 2 : 4;
    list->u.l.items = xrealloc(list->u.l.items,
                               list->u.l.cap * sizeof *list->u.l.items);
  }
  list->u.l.items[list->u.l.len++] = item ? item : krn_none();
}

/* ---------- errors ---------- */

/* env registry lives here (ahead of krn_fail, which reclaims through
 * it); allocation functions follow further below. */
struct KRN_Env {
  KRN_Env *parent;
  char **names;
  KRN_Value **vals;
  size_t len, cap;
  /* global creation-order registry (doubly-linked): lets failure
   * recovery free envs abandoned below a rewind point. */
  unsigned long seq;
  KRN_Env *eprev, *enext;
};

static KRN_Env *envTail = NULL;
static unsigned long envClock = 0;

static int cur_line = -1;
static struct { const char *name; int line; } frames[64];
static int nframes = 0;

/* handler + env + deadline stacks (all dynamic: depth is unbounded) */
static KRN_Handler **hstack = NULL;
static size_t nhand = 0, cahand = 0;

typedef struct {
  const char *owner;
  int line;
  int ms;
  double deadline;
} TmoFrame;

static TmoFrame *tmos = NULL;
static size_t ntmo = 0, catmo = 0;

/* saved failure for catch sites (try) and rethrow */
static char skind[32] = {0};
static int sline = -1;
static char *smsg = NULL;
static char *strace = NULL;

void krn_line(int line) { cur_line = line; }

void krn_push_frame(const char *name, int line) {
  if (nframes < 64) {
    frames[nframes].name = name;
    frames[nframes].line = line;
    nframes++;
  }
}

void krn_pop_frame(void) {
  if (nframes > 0)
    nframes--;
}

/* shared traceback renderer: appends into buf (mirrors the fatal print) */
static void render_trace(Buf *b) {
  int i, show, omitted;
  if (nframes == 0)
    return;
  bufAdd(b, "Traceback (kronyn, innermost last):\n",
         sizeof("Traceback (kronyn, innermost last):\n") - 1);
  if (nframes > 20) {
    omitted = nframes - 20;
    for (i = 0; i < 5; i++)
      bufPrintf(b, "  at %s (line %d)\n", frames[i].name, frames[i].line);
    bufPrintf(b, "  ... (%d frames omitted)\n", omitted);
    show = 15;
    for (i = nframes - show; i < nframes; i++)
      bufPrintf(b, "  at %s (line %d)\n", frames[i].name, frames[i].line);
  } else {
    for (i = 0; i < nframes; i++)
      bufPrintf(b, "  at %s (line %d)\n", frames[i].name, frames[i].line);
  }
}

static void print_saved(void) {
  if (sline >= 0)
    printf("Kronyn error: line %d: %s\n", sline, smsg ? smsg : "");
  else
    printf("Kronyn error: %s\n", smsg ? smsg : "");
  if (strace)
    fwrite(strace, 1, strlen(strace), stdout);
  fflush(stdout);
}

_Noreturn void krn_fail(const char *kind, int line, const char *msg) {
  KRN_Handler *h;
  Buf b;
  /* snapshot the failure (callers often pass stack buffers) */
  strncpy(skind, kind ? kind : "error", sizeof skind - 1);
  skind[sizeof skind - 1] = '\0';
  sline = line;
  free(smsg);
  smsg = xstrndup(msg ? msg : "", msg ? strlen(msg) : 0);
  free(strace);
  bufInit(&b);
  render_trace(&b);
  bufAddC(&b, '\0');
  strace = b.data;
  if (nhand == 0) {
    print_saved();
    free(smsg);
    smsg = NULL;
    free(strace);
    strace = NULL;
    exit(1);
  }
  /* unwind one handler: truncate env + deadline stacks to its depths
   * (deeper frames are unreachable post-rewind; values survive on
   * refcounts, so only whole envs are reclaimed here) */
  h = hstack[--nhand];
  while (envTail && envTail->seq > h->envSeq) {
    KRN_Env *e = envTail;
    envTail = e->eprev;
    if (envTail)
      envTail->enext = NULL;
    krn_free_env_contents(e);
  }
  if (ntmo > h->tmoDepth)
    ntmo = h->tmoDepth;
  longjmp(h->jb, 1);
}

void krn_push_handler(KRN_Handler *h) {
  h->envSeq = envClock;
  h->tmoDepth = ntmo;
  if (nhand == cahand) {
    cahand = cahand ? cahand * 2 : 8;
    hstack = xrealloc(hstack, cahand * sizeof *hstack);
  }
  hstack[nhand++] = h;
}

void krn_pop_handler(void) {
  if (nhand > 0)
    nhand--;
}

_Noreturn void krn_rethrow(void) {
  if (nhand == 0) {
    print_saved();
    exit(1);
  }
  longjmp(hstack[nhand - 1]->jb, 1);
}

const char *krn_err_kind(void) { return skind; }
const char *krn_err_msg(void) { return smsg ? smsg : ""; }
int krn_err_line(void) { return sline; }
const char *krn_err_trace(void) { return strace ? strace : ""; }

/* ---------- cooperative timeouts ---------- */

static double now_ms(void) {
#ifdef _WIN32
  FILETIME ft;
  ULARGE_INTEGER u;
  GetSystemTimePreciseAsFileTime(&ft);
  u.LowPart = ft.dwLowDateTime;
  u.HighPart = ft.dwHighDateTime;
  /* 100ns ticks since 1601-01-01 -> ms since 1970-01-01 */
  return (double)(u.QuadPart / 10000ULL) - 11644473600000.0;
#else
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
#endif
}

void krn_timeout_arm(const char *owner, int line, int ms) {
  double dl = now_ms() + (double)ms;
  if (ntmo > 0 && tmos[ntmo - 1].deadline < dl)
    dl = tmos[ntmo - 1].deadline;
  if (ntmo == catmo) {
    catmo = catmo ? catmo * 2 : 8;
    tmos = xrealloc(tmos, catmo * sizeof *tmos);
  }
  tmos[ntmo].owner = owner;
  tmos[ntmo].line = line;
  tmos[ntmo].ms = ms;
  tmos[ntmo].deadline = dl;
  ntmo++;
}

void krn_timeout_pop(void) {
  if (ntmo > 0)
    ntmo--;
}

void krn_check_timeout(void) {
  if (ntmo > 0 && now_ms() > tmos[ntmo - 1].deadline) {
    char *m = msgf("%s timed out after %dms", tmos[ntmo - 1].owner,
                   tmos[ntmo - 1].ms);
    krn_fail("timeout", tmos[ntmo - 1].line, m);
  }
}

/* ---------- init / argv ---------- */

static char **saved_argv = NULL;
static int saved_argc = 0;

void krn_init(int argc, char **argv) {
  int i;
#ifdef KRN_LEAK_CHECK
  {
    static int registered = 0;
    if (!registered) {
      registered = 1;
      atexit(krn_leak_report);
    }
  }
#endif
  saved_argc = argc < 0 ? 0 : argc;
  if (saved_argc > 0) {
    saved_argv = xmalloc(sizeof *saved_argv * (size_t)saved_argc);
    for (i = 0; i < saved_argc; i++) {
      size_t n = strlen(argv[i]);
      saved_argv[i] = xstrndup(argv[i], n);
    }
  }
}

/* ---------- environments ---------- */

KRN_Env *krn_new_env(KRN_Env *parent) {
  KRN_Env *e = xmalloc(sizeof *e);
#ifdef KRN_LEAK_CHECK
  live_envs++;
#endif
  e->parent = parent;  e->names = NULL;
  e->vals = NULL;
  e->len = 0;
  e->cap = 0;
  e->seq = ++envClock;
  e->eprev = envTail;
  e->enext = NULL;
  if (envTail)
    envTail->enext = e;
  envTail = e;
  return e;
}

static void krn_free_env_contents(KRN_Env *env) {
  size_t i;
  if (!env)
    return;
#ifdef KRN_LEAK_CHECK
  live_envs--;
#endif
  for (i = 0; i < env->len; i++) {
    free(env->names[i]);
    krn_release(env->vals[i]);
  }
  free(env->names);
  free(env->vals);
  free(env);
}

void krn_free_env(KRN_Env *env) {
  if (!env)
    return;
  if (env->eprev)
    env->eprev->enext = env->enext;
  if (env->enext)
    env->enext->eprev = env->eprev;
  if (envTail == env)
    envTail = env->eprev;
  krn_free_env_contents(env);
}

/* M2 tail-call support: drop all locals (params are rebound right after),
 * mirroring the walker's cleared frame per tail iteration. */
void krn_env_clear(KRN_Env *env) {
  size_t i;
  if (!env)
    return;
  for (i = 0; i < env->len; i++) {
    free(env->names[i]);
    krn_release(env->vals[i]);
  }
  env->len = 0;
}

KRN_Value *krn_get(KRN_Env *env, const char *name) {
  size_t i;
  for (; env; env = env->parent)
    for (i = 0; i < env->len; i++)
      if (strcmp(env->names[i], name) == 0)
        return krn_retain(env->vals[i]);
  return krn_str_c("");
}

void krn_set(KRN_Env *env, const char *name, KRN_Value *v) {
  size_t i;
  for (i = 0; i < env->len; i++) {
    if (strcmp(env->names[i], name) == 0) {
      krn_release(env->vals[i]);
      env->vals[i] = krn_retain(v);
      return;
    }
  }
  if (env->len == env->cap) {
    env->cap = env->cap ? env->cap * 2 : 8;
    env->names = xrealloc(env->names, env->cap * sizeof *env->names);
    env->vals = xrealloc(env->vals, env->cap * sizeof *env->vals);
  }
  env->names[env->len] = xstrndup(name, strlen(name));
  env->vals[env->len] = krn_retain(v);
  env->len++;
}

/* ---------- coercion / truth ---------- */

KRN_Value *krn_to_str(KRN_Value *v) {
  size_t i;
  Buf b;
  char num[32];
  if (!v)
    return krn_str_c("");
  switch (v->kind) {
  case KRN_STR:
    return krn_retain(v);
  case KRN_INT:
    snprintf(num, sizeof num, "%lld", v->u.i);
    return krn_str_c(num);
  case KRN_NONE:
    return krn_str_c("");
  case KRN_SOME:
    return krn_to_str(v->u.inner);
  case KRN_LIST:
    bufInit(&b);
    for (i = 0; i < v->u.l.len; i++) {
      KRN_Value *s = krn_to_str(v->u.l.items[i]);
      if (i > 0)
        bufAddC(&b, ' ');
      bufAdd(&b, s->u.s.data, s->u.s.len);
      krn_release(s);
    }
    {
      KRN_Value *r = krn_str(b.data, b.len);
      free(b.data);
      return r;
    }
  }
  return krn_str_c("");
}

const char *krn_kind_name(KRN_Value *v) {
  if (!v)
    return "none";
  switch (v->kind) {
  case KRN_INT: return "int";
  case KRN_STR: return "string";
  case KRN_LIST: return "list";
  case KRN_SOME: return "some";
  default: return "none";
  }
}

static const char *kind_word(KRN_Kind k) {
  switch (k) {
  case KRN_INT: return "int";
  case KRN_STR: return "string";
  case KRN_LIST: return "list";
  case KRN_SOME: return "some";
  default: return "none";
  }
}

void krn_check_kind(KRN_Value *v, KRN_Kind want, const char *proc,
                    const char *param, int line) {
  if (!v || v->kind != want) {
    char *m = msgf("%s expects %s for '%s', got %s", proc,
                   kind_word(want), param, krn_kind_name(v));
    krn_fail("type", line, m);
  }
}

/* M2 call boundaries: return contract and arity (mirrors the define
 * closure messages in eval.nim). */
void krn_check_return(KRN_Value *v, KRN_Kind want, const char *proc, int line) {
  if (!v || v->kind != want) {
    char *m = msgf("%s must return %s, got %s", proc,
                   kind_word(want), krn_kind_name(v));
    krn_fail("type", line, m);
  }
}

void krn_fail_arity(const char *name, int line, int expected, int got) {
  char *m = msgf("%s expects %d args, got %d", name, expected, got);
  krn_fail("arity", line, m);
}

/* warn-once registry for @deprecated (per process, like the
 * interpreter's warned set; redefinition does not exist compiled). */
static const char **depWarned = NULL;
static size_t ndepWarned = 0, cadepWarned = 0;

void krn_warn_deprecated(const char *name, int line, const char *msg) {
  size_t i;
  for (i = 0; i < ndepWarned; i++)
    if (strcmp(depWarned[i], name) == 0)
      return;
  if (ndepWarned == cadepWarned) {
    cadepWarned = cadepWarned ? cadepWarned * 2 : 8;
    depWarned = xrealloc(depWarned, cadepWarned * sizeof *depWarned);
  }
  depWarned[ndepWarned++] = name;
  fprintf(stderr, "Kronyn deprecated: %s (line %d): %s\n", name, line, msg);
  fflush(stderr);
}

int krn_truthy(KRN_Value *v) {  if (!v || v->kind == KRN_NONE)
    return 0;
  switch (v->kind) {
  case KRN_SOME:
    return 1;
  case KRN_INT:
    return v->u.i != 0;
  case KRN_LIST:
    return v->u.l.len > 0;
  case KRN_STR:
    return v->u.s.len != 0 &&
           !(v->u.s.len == 1 && v->u.s.data[0] == '0');
  default:
    return 0;
  }
}

/* strict word-integer test: optional sign, then digits only (no space) */
int krn_is_intval(KRN_Value *v, long long *out) {
  size_t i = 0;
  int neg = 0;
  long long acc = 0;
  if (!v)
    return 0;
  if (v->kind == KRN_INT) {
    if (out)
      *out = v->u.i;
    return 1;
  }
  if (v->kind != KRN_STR || v->u.s.len == 0)
    return 0;
  if (v->u.s.data[0] == '-') {
    neg = 1;
    i = 1;
  } else if (v->u.s.data[0] == '+') {
    i = 1;
  }
  if (i >= v->u.s.len)
    return 0;
  for (; i < v->u.s.len; i++) {
    char c = v->u.s.data[i];
    if (c < '0' || c > '9')
      return 0;
    acc = acc * 10 + (c - '0');
  }
  if (out)
    *out = neg ? -acc : acc;
  return 1;
}

/* tolerant conversion (leading/trailing space, sign); fails kind "error" */
long long krn_as_int(KRN_Value *v) {
  KRN_Value *s;
  const char *p;
  size_t i = 0, n;
  int neg = 0;
  long long acc = 0;
  int digits = 0;
  if (v && v->kind == KRN_INT)
    return v->u.i;
  s = krn_to_str(v);
  p = s->u.s.data;
  n = s->u.s.len;
  while (i < n && isspace((unsigned char)p[i]))
    i++;
  if (i < n && (p[i] == '-' || p[i] == '+')) {
    neg = p[i] == '-';
    i++;
  }
  while (i < n && p[i] >= '0' && p[i] <= '9') {
    acc = acc * 10 + (p[i] - '0');
    digits++;
    i++;
  }
  while (i < n && isspace((unsigned char)p[i]))
    i++;
  if (!digits || i != n) {
    char *msg = msgf("invalid integer: '%.*s'", (int)n, p);
    krn_release(s);
    krn_fail("error", -1, msg);
  }
  krn_release(s);
  return neg ? -acc : acc;
}

static void fail_expected_int(KRN_Value *v) {
  KRN_Value *s = krn_to_str(v);
  char *m = msgf("expected integer, got '%s'", s->u.s.data);
  krn_release(s);
  krn_fail("type", cur_line, m);
}

/* ---------- operators ---------- */

KRN_Value *krn_concat(KRN_Value *a, KRN_Value *b) {
  KRN_Value *sa = krn_to_str(a);
  KRN_Value *sb = krn_to_str(b);
  Buf buf;
  KRN_Value *r;
  bufInit(&buf);
  bufAdd(&buf, sa->u.s.data, sa->u.s.len);
  bufAdd(&buf, sb->u.s.data, sb->u.s.len);
  r = krn_str(buf.data, buf.len);
  free(buf.data);
  krn_release(sa);
  krn_release(sb);
  return r;
}

KRN_Value *krn_add(KRN_Value *a, KRN_Value *b) {
  long long x, y;
  if (krn_is_intval(a, &x) && krn_is_intval(b, &y))
    return krn_int(x + y);
  return krn_concat(a, b);
}

KRN_Value *krn_sub(KRN_Value *a, KRN_Value *b) {
  long long x, y;
  if (!krn_is_intval(a, &x))
    fail_expected_int(a);
  if (!krn_is_intval(b, &y))
    fail_expected_int(b);
  return krn_int(x - y);
}

KRN_Value *krn_mul(KRN_Value *a, KRN_Value *b) {
  long long x, y;
  if (!krn_is_intval(a, &x))
    fail_expected_int(a);
  if (!krn_is_intval(b, &y))
    fail_expected_int(b);
  return krn_int(x * y);
}

KRN_Value *krn_divide(KRN_Value *a, KRN_Value *b) {
  long long x, y;
  if (!krn_is_intval(a, &x))
    fail_expected_int(a);
  if (!krn_is_intval(b, &y))
    fail_expected_int(b);
  if (y == 0)
    krn_fail("division", cur_line, "division by zero");
  return krn_int(x / y);
}

static int str_eq(KRN_Value *a, KRN_Value *b) {
  KRN_Value *sa = krn_to_str(a);
  KRN_Value *sb = krn_to_str(b);
  int eq = sa->u.s.len == sb->u.s.len &&
           memcmp(sa->u.s.data, sb->u.s.data, sa->u.s.len) == 0;
  krn_release(sa);
  krn_release(sb);
  return eq;
}

KRN_Value *krn_eq(KRN_Value *a, KRN_Value *b) {
  if (a && a->kind == KRN_INT && b && b->kind == KRN_INT)
    return krn_int(a->u.i == b->u.i ? 1 : 0);
  if (a && a->kind == KRN_STR && b && b->kind == KRN_STR) {
    int eq = a->u.s.len == b->u.s.len &&
             memcmp(a->u.s.data, b->u.s.data, a->u.s.len) == 0;
    return krn_int(eq ? 1 : 0);
  }
  return krn_int(str_eq(a, b) ? 1 : 0);
}

KRN_Value *krn_ne(KRN_Value *a, KRN_Value *b) {
  KRN_Value *e = krn_eq(a, b);
  long long v = e->u.i;
  krn_release(e);
  return krn_int(v ? 0 : 1);
}

KRN_Value *krn_lt(KRN_Value *a, KRN_Value *b) {
  return krn_int(krn_as_int(a) < krn_as_int(b) ? 1 : 0);
}

KRN_Value *krn_gt(KRN_Value *a, KRN_Value *b) {
  return krn_int(krn_as_int(a) > krn_as_int(b) ? 1 : 0);
}

KRN_Value *krn_lte(KRN_Value *a, KRN_Value *b) {
  return krn_int(krn_as_int(a) <= krn_as_int(b) ? 1 : 0);
}

KRN_Value *krn_gte(KRN_Value *a, KRN_Value *b) {
  return krn_int(krn_as_int(a) >= krn_as_int(b) ? 1 : 0);
}

KRN_Value *krn_kand(KRN_Value *a, KRN_Value *b) {
  return krn_int(krn_truthy(a) && krn_truthy(b) ? 1 : 0);
}

KRN_Value *krn_kor(KRN_Value *a, KRN_Value *b) {
  return krn_int(krn_truthy(a) || krn_truthy(b) ? 1 : 0);
}

KRN_Value *krn_knot(KRN_Value *a) {
  return krn_int(krn_truthy(a) ? 0 : 1);
}

/* ---------- builtins ---------- */

static KRN_Value *empty_str(void) { return krn_str_c(""); }

KRN_Value *krn_b_writeln(KRN_Value *a) {
  KRN_Value *s = krn_to_str(a);
  fwrite(s->u.s.data, 1, s->u.s.len, stdout);
  putchar('\n');
  fflush(stdout);
  krn_release(s);
  return empty_str();
}

KRN_Value *krn_b_write(KRN_Value *a) {
  KRN_Value *s = krn_to_str(a);
  fwrite(s->u.s.data, 1, s->u.s.len, stdout);
  fflush(stdout);
  krn_release(s);
  return empty_str();
}

static KRN_Value *read_stdin_line(void) {
  Buf buf;
  int c, any = 0;
  KRN_Value *r;
  bufInit(&buf);
  while ((c = getchar()) != EOF) {
    any = 1;
    if (c == '\n')
      break;
    bufAddC(&buf, (char)c);
  }
  if (!any) {
    free(buf.data);
    krn_fail("io", -1, "end of input");
  }
  while (buf.len > 0 && buf.data[buf.len - 1] == '\r')
    buf.len--;
  r = krn_str(buf.data, buf.len);
  free(buf.data);
  return r;
}

KRN_Value *krn_b_input(void) { return read_stdin_line(); }
KRN_Value *krn_b_readln(void) { return read_stdin_line(); }

KRN_Value *krn_b_toUpper(KRN_Value *a) {
  KRN_Value *s = krn_to_str(a);
  size_t i;
  KRN_Value *r;
  char *p = xstrndup(s->u.s.data, s->u.s.len);
  for (i = 0; i < s->u.s.len; i++)
    p[i] = (char)toupper((unsigned char)p[i]);
  r = krn_str(p, s->u.s.len);
  free(p);
  krn_release(s);
  return r;
}

KRN_Value *krn_b_toLower(KRN_Value *a) {
  KRN_Value *s = krn_to_str(a);
  size_t i;
  KRN_Value *r;
  char *p = xstrndup(s->u.s.data, s->u.s.len);
  for (i = 0; i < s->u.s.len; i++)
    p[i] = (char)tolower((unsigned char)p[i]);
  r = krn_str(p, s->u.s.len);
  free(p);
  krn_release(s);
  return r;
}

KRN_Value *krn_b_len(KRN_Value *a) {
  if (a && a->kind == KRN_LIST)
    return krn_int((long long)a->u.l.len);
  {
    KRN_Value *s = krn_to_str(a);
    KRN_Value *r = krn_int((long long)s->u.s.len);
    krn_release(s);
    return r;
  }
}

KRN_Value *krn_b_trim(KRN_Value *a) {
  KRN_Value *s = krn_to_str(a);
  size_t i = 0, j = s->u.s.len;
  KRN_Value *r;
  while (i < j && isspace((unsigned char)s->u.s.data[i]))
    i++;
  while (j > i && isspace((unsigned char)s->u.s.data[j - 1]))
    j--;
  r = krn_str(s->u.s.data + i, j - i);
  krn_release(s);
  return r;
}

KRN_Value *krn_b_ascii(KRN_Value *a) {
  KRN_Value *s = krn_to_str(a);
  KRN_Value *r;
  if (s->u.s.len == 0) {
    krn_release(s);
    return krn_int(0);
  }
  r = krn_int((long long)(unsigned char)s->u.s.data[0]);
  krn_release(s);
  return r;
}

KRN_Value *krn_b_char(KRN_Value *a) {
  long long code = krn_as_int(a);
  char c;
  if (code < 0 || code > 255) {
    char *m = msgf("char code out of range: %lld", code);
    krn_fail("bounds", cur_line, m);
  }
  c = (char)code;
  return krn_str(&c, 1);
}

KRN_Value *krn_b_int(KRN_Value *a) { return krn_int(krn_as_int(a)); }
KRN_Value *krn_b_str(KRN_Value *a) { return krn_to_str(a); }

KRN_Value *krn_b_typeof(KRN_Value *a) {
  const char *t = "none";
  if (a) {
    switch (a->kind) {
    case KRN_INT: t = "int"; break;
    case KRN_STR: t = "string"; break;
    case KRN_LIST: t = "list"; break;
    case KRN_SOME: t = "some"; break;
    case KRN_NONE: t = "none"; break;
    }
  }
  return krn_str_c(t);
}

KRN_Value *krn_b_isInt(KRN_Value *a) {
  return krn_int(a && a->kind == KRN_INT ? 1 : 0);
}

KRN_Value *krn_b_isString(KRN_Value *a) {
  return krn_int(a && a->kind == KRN_STR ? 1 : 0);
}

KRN_Value *krn_b_isList(KRN_Value *a) {
  return krn_int(a && a->kind == KRN_LIST ? 1 : 0);
}

KRN_Value *krn_b_slice(KRN_Value *a, KRN_Value *b, KRN_Value *c) {
  KRN_Value *s = krn_to_str(a);
  long long from = krn_as_int(b);
  long long to = krn_as_int(c);
  KRN_Value *r;
  if (from < 0 || to > (long long)s->u.s.len || from > to) {
    krn_release(s);
    krn_fail("bounds", cur_line, "slice out of bounds");
  }
  r = krn_str(s->u.s.data + from, (size_t)(to - from));
  krn_release(s);
  return r;
}

KRN_Value *krn_b_index(KRN_Value *a, KRN_Value *b) {
  KRN_Value *s = krn_to_str(a);
  long long idx = krn_as_int(b);
  KRN_Value *r;
  if (idx < 0 || idx >= (long long)s->u.s.len) {
    krn_release(s);
    krn_fail("bounds", cur_line, "index out of bounds");
  }
  r = krn_str(s->u.s.data + idx, 1);
  krn_release(s);
  return r;
}

KRN_Value *krn_b_contains(KRN_Value *a, KRN_Value *b) {
  KRN_Value *sa = krn_to_str(a);
  KRN_Value *sb = krn_to_str(b);
  KRN_Value *r;
  /* memmem-style substring search (strstr needs NUL, strings are binary) */
  size_t i, found = 0;
  if (sb->u.s.len == 0) {
    found = 1;
  } else {
    for (i = 0; i + sb->u.s.len <= sa->u.s.len; i++) {
      if (memcmp(sa->u.s.data + i, sb->u.s.data, sb->u.s.len) == 0) {
        found = 1;
        break;
      }
    }
  }
  r = krn_str_c(found ? "true" : "false");
  krn_release(sa);
  krn_release(sb);
  return r;
}

KRN_Value *krn_b_replace(KRN_Value *a, KRN_Value *b, KRN_Value *c) {
  KRN_Value *sa = krn_to_str(a);
  KRN_Value *sb = krn_to_str(b);
  KRN_Value *sc = krn_to_str(c);
  Buf buf;
  KRN_Value *r;
  size_t i = 0;
  bufInit(&buf);
  if (sb->u.s.len == 0) {
    bufAdd(&buf, sa->u.s.data, sa->u.s.len);
  } else {
    while (i < sa->u.s.len) {
      if (i + sb->u.s.len <= sa->u.s.len &&
          memcmp(sa->u.s.data + i, sb->u.s.data, sb->u.s.len) == 0) {
        bufAdd(&buf, sc->u.s.data, sc->u.s.len);
        i += sb->u.s.len;
      } else {
        bufAddC(&buf, sa->u.s.data[i]);
        i++;
      }
    }
  }
  r = krn_str(buf.data, buf.len);
  free(buf.data);
  krn_release(sa);
  krn_release(sb);
  krn_release(sc);
  return r;
}

KRN_Value *krn_b_split(KRN_Value *a, KRN_Value *b) {
  KRN_Value *sa = krn_to_str(a);
  KRN_Value *sb = krn_to_str(b);
  KRN_Value *r = krn_list_new();
  size_t i = 0, start = 0;
  if (sb->u.s.len == 0) {
    krn_list_append(r, krn_str(sa->u.s.data, sa->u.s.len));
  } else {
    while (i < sa->u.s.len) {
      if (i + sb->u.s.len <= sa->u.s.len &&
          memcmp(sa->u.s.data + i, sb->u.s.data, sb->u.s.len) == 0) {
        krn_list_append(r, krn_str(sa->u.s.data + start, i - start));
        i += sb->u.s.len;
        start = i;
      } else {
        i++;
      }
    }
    krn_list_append(r, krn_str(sa->u.s.data + start, i - start));
  }
  krn_release(sa);
  krn_release(sb);
  return r;
}

KRN_Value *krn_b_concat(KRN_Value *a, KRN_Value *b) {
  return krn_concat(a, b);
}

KRN_Value *krn_b_mod(KRN_Value *a, KRN_Value *b) {
  long long x = krn_as_int(a);
  long long y = krn_as_int(b);
  if (y == 0)
    krn_fail("division", cur_line, "division by zero");
  return krn_int(x % y);
}

/* Shell out and capture merged output (the walker merges child stderr
 * the same way). Exit status is ignored; the stripped text returns. */
KRN_Value *krn_b_exec(KRN_Value *a) {
  KRN_Value *sc = krn_to_str(a);
  Buf cmd;
  Buf out;
  char chunk[4096];
  size_t n;
  KRN_Value *r;
  size_t s, e;
#ifdef _WIN32
#define KRN_POPEN _popen
#define KRN_PCLOSE _pclose
#else
#define KRN_POPEN popen
#define KRN_PCLOSE pclose
#endif
  FILE *p;
  bufInit(&cmd);
  bufAdd(&cmd, sc->u.s.data, sc->u.s.len);
  bufAdd(&cmd, " 2>&1", 5);
  bufAddC(&cmd, '\0');
  p = KRN_POPEN(cmd.data, "r");
  free(cmd.data);
  if (!p) {
    char *m = msgf("exec failed: %s", strerror(errno));
    krn_release(sc);
    krn_fail("io", cur_line, m);
  }
  bufInit(&out);
  while ((n = fread(chunk, 1, sizeof chunk, p)) > 0)
    bufAdd(&out, chunk, n);
  KRN_PCLOSE(p);
  krn_release(sc);
  s = 0;
  e = out.len;
  while (s < e && isspace((unsigned char)out.data[s]))
    s++;
  while (e > s && isspace((unsigned char)out.data[e - 1]))
    e--;
  r = krn_str(out.data + s, e - s);
  free(out.data);
  return r;
}

/* split a string value on '\n', keeping empties */
static KRN_Value *split_lines(KRN_Value *a) {
  KRN_Value *s = krn_to_str(a);
  KRN_Value *r = krn_list_new();
  size_t i = 0, start = 0;
  while (i < s->u.s.len) {
    if (s->u.s.data[i] == '\n') {
      krn_list_append(r, krn_str(s->u.s.data + start, i - start));
      i++;
      start = i;
    } else {
      i++;
    }
  }
  krn_list_append(r, krn_str(s->u.s.data + start, i - start));
  krn_release(s);
  return r;
}

KRN_Value *krn_b_lines(KRN_Value *a) { return split_lines(a); }

KRN_Value *krn_b_filter(KRN_Value *a, KRN_Value *b) {
  KRN_Value *lines = split_lines(a);
  KRN_Value *sb = krn_to_str(b);
  Buf buf;
  KRN_Value *r;
  size_t i;
  int first = 1;
  bufInit(&buf);
  for (i = 0; i < lines->u.l.len; i++) {
    KRN_Value *ln = lines->u.l.items[i];
    KRN_Value *ls = krn_to_str(ln);
    size_t j, found = 0;
    if (sb->u.s.len == 0) {
      found = 1;
    } else {
      for (j = 0; j + sb->u.s.len <= ls->u.s.len; j++) {
        if (memcmp(ls->u.s.data + j, sb->u.s.data, sb->u.s.len) == 0) {
          found = 1;
          break;
        }
      }
    }
    if (found) {
      if (!first)
        bufAddC(&buf, '\n');
      bufAdd(&buf, ls->u.s.data, ls->u.s.len);
      first = 0;
    }
    krn_release(ls);
  }
  r = krn_str(buf.data, buf.len);
  free(buf.data);
  krn_release(lines);
  krn_release(sb);
  return r;
}

KRN_Value *krn_b_count(KRN_Value *a) {
  KRN_Value *lines = split_lines(a);
  size_t i, n = 0;
  for (i = 0; i < lines->u.l.len; i++) {
    KRN_Value *ls = krn_to_str(lines->u.l.items[i]);
    if (ls->u.s.len > 0)
      n++;
    krn_release(ls);
  }
  krn_release(lines);
  return krn_int((long long)n);
}

static KRN_Value *first_last(KRN_Value *a, int want_last) {
  KRN_Value *lines = split_lines(a);
  size_t i;
  KRN_Value *r = empty_str();
  if (!want_last) {
    for (i = 0; i < lines->u.l.len; i++) {
      KRN_Value *ls = krn_to_str(lines->u.l.items[i]);
      if (ls->u.s.len > 0) {
        krn_release(r);
        r = ls;
        break;
      }
      krn_release(ls);
    }
  } else {
    for (i = lines->u.l.len; i-- > 0;) {
      KRN_Value *ls = krn_to_str(lines->u.l.items[i]);
      if (ls->u.s.len > 0) {
        krn_release(r);
        r = ls;
        break;
      }
      krn_release(ls);
    }
  }
  krn_release(lines);
  return r;
}

KRN_Value *krn_b_first(KRN_Value *a) { return first_last(a, 0); }
KRN_Value *krn_b_last(KRN_Value *a) { return first_last(a, 1); }

KRN_Value *krn_b_some(KRN_Value *a) { return krn_some(krn_retain(a)); }
KRN_Value *krn_b_none(void) { return krn_none(); }

KRN_Value *krn_b_somep(KRN_Value *a) {
  return krn_int(a && a->kind == KRN_SOME ? 1 : 0);
}

KRN_Value *krn_b_nonep(KRN_Value *a) {
  return krn_int(!a || a->kind == KRN_NONE ? 1 : 0);
}

KRN_Value *krn_b_unwrap(KRN_Value *a) {
  if (!a || a->kind != KRN_SOME)
    krn_fail("option", cur_line, "unwrap called on none");
  return krn_retain(a->u.inner);
}

KRN_Value *krn_b_unwrapOr(KRN_Value *a, KRN_Value *b) {
  if (a && a->kind == KRN_SOME)
    return krn_retain(a->u.inner);
  return krn_retain(b);
}

/* ---------- syscalls ---------- */

KRN_Value *krn_sys_io_output(KRN_Value *a) {
  KRN_Value *s = krn_to_str(a);
  fwrite(s->u.s.data, 1, s->u.s.len, stdout);
  fflush(stdout);
  krn_release(s);
  return empty_str();
}

KRN_Value *krn_sys_io_outputln(KRN_Value *a) {
  KRN_Value *s = krn_to_str(a);
  fwrite(s->u.s.data, 1, s->u.s.len, stdout);
  putchar('\n');
  fflush(stdout);
  krn_release(s);
  return empty_str();
}

KRN_Value *krn_sys_io_input(void) { return read_stdin_line(); }

KRN_Value *krn_sys_fs_read(KRN_Value *a) {
  KRN_Value *sp = krn_to_str(a);
  FILE *f = fopen(sp->u.s.data, "rb");
  Buf buf;
  KRN_Value *r;
  size_t n;
  char chunk[8192];
  if (!f) {
    krn_release(sp);
    return krn_none();
  }
  bufInit(&buf);
  while ((n = fread(chunk, 1, sizeof chunk, f)) > 0)
    bufAdd(&buf, chunk, n);
  if (ferror(f)) {
    fclose(f);
    free(buf.data);
    krn_release(sp);
    return krn_none();
  }
  fclose(f);
  r = krn_some(krn_str(buf.data, buf.len));
  free(buf.data);
  krn_release(sp);
  return r;
}

static KRN_Value *fs_write_impl(KRN_Value *a, KRN_Value *b, const char *mode,
                                const char *what) {
  KRN_Value *sp = krn_to_str(a);
  KRN_Value *sc = krn_to_str(b);
  FILE *f = fopen(sp->u.s.data, mode);
  if (!f) {
    char *m = msgf("%s failed: %s", what, strerror(errno));
    krn_release(sp);
    krn_release(sc);
    krn_fail("io", cur_line, m);
  }
  fwrite(sc->u.s.data, 1, sc->u.s.len, f);
  fclose(f);
  krn_release(sp);
  krn_release(sc);
  return empty_str();
}

KRN_Value *krn_sys_fs_write(KRN_Value *a, KRN_Value *b) {
  return fs_write_impl(a, b, "wb", "fs.write");
}

KRN_Value *krn_sys_fs_append(KRN_Value *a, KRN_Value *b) {
  return fs_write_impl(a, b, "ab", "fs.append");
}

KRN_Value *krn_sys_fs_exists(KRN_Value *a) {
  KRN_Value *sp = krn_to_str(a);
  FILE *f = fopen(sp->u.s.data, "rb");
  int ok = f != NULL;
  if (f)
    fclose(f);
  krn_release(sp);
  return krn_int(ok ? 1 : 0);
}

KRN_Value *krn_sys_fs_remove(KRN_Value *a) {
  KRN_Value *sp = krn_to_str(a);
  FILE *probe;
  KRN_Value *r;
  probe = fopen(sp->u.s.data, "rb");
  if (!probe) {
    krn_release(sp);
    return krn_none();
  }
  fclose(probe);
  if (remove(sp->u.s.data) != 0) {
    char *m = msgf("fs.remove failed: %s", strerror(errno));
    krn_release(sp);
    krn_fail("io", cur_line, m);
  }
  r = empty_str();
  krn_release(sp);
  return r;
}

static int cmp_strptr(const void *x, const void *y) {
  return strcmp(*(char *const *)x, *(char *const *)y);
}

KRN_Value *krn_sys_fs_list(KRN_Value *a) {
  KRN_Value *sp = krn_to_str(a);
  KRN_Value *r = NULL;
#ifdef _WIN32
  {
    char *pat;
    WIN32_FIND_DATAA fd;
    HANDLE h;
    char **names = NULL;
    size_t n = 0, cap = 0, i;
    pat = xmalloc(sp->u.s.len + 4);
    memcpy(pat, sp->u.s.data, sp->u.s.len);
    memcpy(pat + sp->u.s.len, "\\*", 3);
    h = FindFirstFileA(pat, &fd);
    free(pat);
    if (h == INVALID_HANDLE_VALUE) {
      krn_release(sp);
      return krn_none();
    }
    do {
      size_t nl = strlen(fd.cFileName);
      if (n == cap) {
        cap = cap ? cap * 2 : 16;
        names = xrealloc(names, cap * sizeof *names);
      }
      names[n] = xstrndup(fd.cFileName, nl);
      n++;
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    if (n > 0)
      qsort(names, n, sizeof *names, cmp_strptr);
    r = krn_list_new();
    for (i = 0; i < n; i++) {
      krn_list_append(r, krn_str_c(names[i]));
      free(names[i]);
    }
    free(names);
  }
#else
  {
    DIR *d = opendir(sp->u.s.data);
    struct dirent *e;
    char **names = NULL;
    size_t n = 0, cap = 0, i;
    if (!d) {
      krn_release(sp);
      return krn_none();
    }
    while ((e = readdir(d)) != NULL) {
      size_t nl = strlen(e->d_name);
      if (n == cap) {
        cap = cap ? cap * 2 : 16;
        names = xrealloc(names, cap * sizeof *names);
      }
      names[n] = xstrndup(e->d_name, nl);
      n++;
    }
    closedir(d);
    if (n > 0)
      qsort(names, n, sizeof *names, cmp_strptr);
    r = krn_list_new();
    for (i = 0; i < n; i++) {
      krn_list_append(r, krn_str_c(names[i]));
      free(names[i]);
    }
    free(names);
  }
#endif
  krn_release(sp);
  return r;
}

KRN_Value *krn_sys_proc_exit(int argc, KRN_Value **argv) {
  long long code = 0;
  if (argc > 0)
    code = krn_as_int(argv[0]);
  fflush(stdout);
  exit((int)code);
  return empty_str();
}

KRN_Value *krn_sys_proc_args(void) {
  KRN_Value *r = krn_list_new();
  int i;
  for (i = 0; i < saved_argc; i++)
    krn_list_append(r, krn_str_c(saved_argv[i]));
  return r;
}
