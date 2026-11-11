# Coroutines

Rule of thumb: reach for a coroutine when your instinct is to write a state machine, a callback chain, or an infinite while loop with a chunk of work per iteration — those are exactly what coroutines collapse into readable, linear code

# Coroutine Lifecycle

Lua coroutines have four statuses, reported by `coroutine.status(co)`:

| Status       | Meaning |
|--------------|---------|
| `suspended`  | Created or paused, waiting for a resume |
| `running`    | Currently executing |
| `normal`     | Alive, but currently executing its resumer (it resumed someone else) |
| `dead`       | Body returned or raised an error — terminal state |

```mermaid
stateDiagram-v2
    direction LR

    [*] --> Suspended : coroutine.create(f)\n(+ coroutine.wrap(f))

    state "suspended" as Suspended
    state "running" as Running
    state "normal" as Normal
    state "dead" as Dead

    Suspended --> Running : coroutine.resume(co, ...)\nargs -> body params (1st) / yield returns (later)
    Running --> Suspended : coroutine.yield(...)\nyielded values -> resume() return values
    Running --> Running : coroutine.yield()\nyieldable C call (pcall, metamethod)\ncontinuation saved, resumed later
    Running --> Dead : body returns\n-> resume() returns true + rets
    Running --> Dead : error raised\n-> resume() returns false, err

    Normal --> Running : its child yields/returns\ncontrol returns here
    Running --> Normal : this thread resumed\nanother coroutine

    Suspended --> Dead : coroutine.close(co)\n(5.4+) runs pending <close> handlers

    Dead --> Dead : resume(dead) -> error\n"cannot resume dead coroutine"
    Running --> Running2 : resume(self/running)\n-> error "cannot resume running coroutine"
    state Running2 {
    }
    note right of Suspended
        resume() on a "normal" coroutine
        -> error "cannot resume non-suspended coroutine"
    end note
```

The same flow in plain text:

```
                         coroutine.create(f)
                                │
                                ▼
   ┌─────────────────────> suspended ◂──────────────────────┐
   │                            │                           │
   │   coroutine.resume(co, ...)│                           │ coroutine.yield(...)
   │   caller becomes "normal"  ▼                           │ (or body returns / error)
   │                  ┌──────────────┐                      │
   │                  │    running   │──────────────────────┤
   │                  └──────┬───────┘                      │
   │        resumed another  │                              │
   │         coroutine       ▼                              │
   │                  ┌──────────────┐   child yields/ends ┌┴─────────────┐
   └──────────────────│    normal    │─────────────────────▶│     dead     │
                      └──────────────┘                      └──────┬───────┘
                                                                   │
                                                     resume(dead) ✗ error
```

Key invariants of the transitions:

- **`resume` and `yield` always come in pairs.** `yield` never returns control to "the scheduler" — it returns to the *exact* `coroutine.resume` call that entered the coroutine, and yielded values become that resume call's return values.
- **Exactly one thread is `running` at any moment.** When coroutine A resumes coroutine B, A drops to `normal` for the duration; when B yields or returns, A is `running` again.
- **`dead` is terminal.** After the body returns or errors, further resumes fail with `"cannot resume dead coroutine"`. In 5.4 `coroutine.close` is the only way to force a suspended coroutine to `dead` (running its pending `<close>` handlers first).
- **Errors do not propagate across the boundary.** `coroutine.resume` catches any error inside the coroutine and returns `false, errmsg` — a deliberate isolation mechanism, similar to `pcall`.
- **`coroutine.wrap` hides the states.** It returns a plain function that resumes on every call and re-raises errors to the caller instead of returning `false, err`.
- **Statuses are per-thread and cheap.** `coroutine.status` and `coroutine.isyieldable` just read the thread's flags; no scheduling machinery is involved.

# Coroutine Internals: `lua_State`

## 1. The two-layer architecture: `lua_State` vs `global_State`

Lua splits its state into two C structures (`lstate.h`):

```
global_State (one per interpreter, created by lua_newstate)
├── mainthread: lua_State          ← the "main" coroutine
├── stringtable strt               ← interned string hash table
├── registry (LUA_REGISTRYINDEX)   ← where C code anchors values
├── GC bookkeeping:
│   ├── allgc / fixedgc / finobj / tobefnz   ← object lists
│   ├── gray / grayagain / weak / allweak / ephemeron ← mark lists
│   ├── GCdebt, GCestimate, gcpause, gcstepmul...
├── all memory bookkeeping, panic function, allocator pointer
└── every lua_State* you ever created
```

```
lua_State (one per thread — main thread AND every coroutine)
├── top          ← first free slot of this thread's value stack
├── stack        ← base of the stack (dynamically grown array of TValue)
├── stack_last   ← end of usable stack area
├── tbclist      ← head of the to-be-closed (<close>) variable list
├── ci           ← pointer to the current CallInfo (current call frame)
├── base_ci      ← the permanent bottom frame of this thread
├── openupval    ← list of open upvalues pointing into this stack
├── twups        ← next thread with open upvalues (global chain)
├── errorJmp     ← current error/yield recovery point (setjmp record)
├── status       ← LUA_OK / LUA_YIELD / error code
├── nCcalls, ncalls ← C-recursion depth counters (overflow guards)
├── hookmask, hookcount... ← debug hook state
└── l_G          ← back-pointer to the shared global_State
```

So: **the heap (tables, strings, functions, the GC) is shared; only the execution context — the value stack, call frames, error handlers, hooks — is per-thread.** `lua_State` is called "a thread" everywhere in the source, and the manual says a coroutine is just "an independent thread of execution." There is no separate "coroutine" type: `coroutine.create` returns a full `lua_State`, and `type(co)` is `"thread"`.

## 2. Thread creation (`lua_newthread` / `luaE_newthread`)

`coroutine.create(f)` → `luaB_cocreate` → `lua_newthread(L)` (`lapi.c`) → `luaE_newthread` (`lstate.c`), which:

1. Allocates a `lua_State` via `luaC_newobj` — it's born as a **GCObject linked into `g->allgc`**, so the GC owns it from birth.
2. Allocates the initial value stack: `BASIC_STACK_SIZE = 2 * LUAI_MINSTACK` = **40 slots** plus `EXTRA_STACK` (5 "hard" slots reserved for the C API). Tiny on purpose — stacks grow on demand.
3. Fills the stack with `nil`, sets `top`, installs `base_ci` (the permanent bottom `CallInfo`, marked `CIST_C`).
4. **Links the thread into the global list of threads** (via the GC list mechanism) so the collector can traverse it.

The new thread is **pushed onto the parent's stack** (`lua_newthread` leaves it there) — that's the anchoring that keeps it alive until the GC runs. Then `luaB_cocreate` moves `f` and the arguments onto the coroutine's stack — `f` becomes the value at the bottom, ready to be "called" by the first resume.

## 3. The call frame: `CallInfo`

Every active function call is described by a `CallInfo` record in a per-thread array (`L->ci` walks the chain via `previous`/`next`):

```c
typedef struct CallInfo {
  StkIdRel func;        /* where the function is on the stack */
  StkIdRel top;         /* top of this frame's stack region */
  struct CallInfo *previous, *next;   /* dynamic call chain */
  union {
    struct {            /* Lua frames */
      const Instruction *savedpc;   /* resume point in the bytecode */
      volatile l_signalT trap;
      int nextraargs;
    } l;
    struct {            /* C frames */
      lua_KFunction k;  /* continuation to resume this call after yield */
      ptrdiff_t old_errfunc;
      lua_KContext ctx;
      int nresults;
    } c;
  } u;
  short nresults;       /* expected number of results */
  unsigned short callstatus;  /* CIST_C, CIST_YPCALL, CIST_TBC, ... */
} CallInfo;
```

Two things make coroutines possible:

- `savedpc` — a Lua frame records *exactly which bytecode instruction* it was about to execute. Suspend/resume is just "stop here / continue here."
- `u.c.k` — a **C frame can store a continuation function**, so a yield can pass *through* C code (that's the yieldable-`pcall` mechanism).

Growing frames are heap-allocated (`luaE_extendCI`), never on the C stack — that's why deep Lua recursion doesn't overflow the native stack, and why `luaD_reallocstack` can safely move the whole value stack: frames store *offsets* that get fixed up after reallocation.

## 4. `coroutine.resume`, step by step (`lcorolib.c` → `lapi.c` → `ldo.c`)

`coroutine.resume(co, ...)` runs `auxresume`:

1. `lua_xmove(L, co, narg)` — moves the arguments from the resumer's stack onto the coroutine's stack.
2. `lua_resume(co, L, narg, &nres)` — the heart:

   - **Guards.** `L->nCcalls` is inherited from the resumer (`from` parameter): nested resumes accumulate C depth, and exceeding `LUAI_MAXCCALLS` (≈200) raises "C stack overflow" *before* the process dies. Resuming a thread that is itself mid-resume or mid-execution is rejected here ("cannot resume ... coroutine").
   - **Sets up the recovery point:** `luaD_rawrunprotected(co, resume, &nargs)` installs `co->errorJmp` (a setjmp record) and runs the helper below.
   - `resume(co, &nargs)` (`ldo.c`), simplified:

     ```c
     static void resume (lua_State *L, void *ud) {
       int n = *(int*)ud;                  /* number of arguments */
       StkId firstArg = L->top - n;
       CallInfo *ci = L->ci;
       if (L->status == LUA_OK)            /* FIRST resume */
         ccall(L, ci->func, n - 1, ...);   /* just call the body function */
       else {                              /* RESUME AFTER YIELD */
         L->status = LUA_OK;               /* mark as running again */
         luaD_poscall(L, ci, n);           /* complete the interrupted call
                                              with the new args as results */
         unroll(L, NULL);                  /* rebuild all outer frames */
       }
     }
     ```

   - On the **first resume** it's simply a normal call of the body `f` (`ccall` → `luaD_precall` → `luaV_execute` starts the interpreter loop on the coroutine's stack).
   - On a **resume after yield**, the saved state is replayed: `unroll()` walks the `CallInfo` chain from the innermost frame outward:
     - **Lua frame** → `luaV_finishOp(L)` finishes the interrupted instruction, then `luaV_execute(L, ci)` re-enters the interpreter loop at `savedpc`.
     - **C frame** → `finishCcall(L, ci)` calls the stored continuation `ci->u.c.k(L, status, ctx)` — this is how `pcall`, metamethods, and iterators survive a yield: they never resume by re-entering their C code; their *continuation function* takes over.

3. **How execution ends and returns.** The interpreter runs until:
   - `coroutine.yield` → `lua_yieldk` (`lapi.c`) sets `L->status = LUA_YIELD`, stores `nresults`, and calls `luaD_throw(L, LUA_YIELD)` — a **`longjmp` back to the setjmp point that `lua_resume` installed**. That's the entire "suspend": abandon the nested C frames, jump out, return `LUA_YIELD`. The coroutine's `savedpc`/`CallInfo` chain is untouched, which is precisely what makes it resumable.
   - Body returns → `luaD_poscall` moves return values onto the coroutine stack, `lua_resume` returns `LUA_OK`.
   - Error → caught by the same `rawrunprotected` (errors are also `longjmp`s); thread is left dead.

4. `auxresume` then does `lua_xmove(co, L, nres)` — results move back to the resumer's stack — and maps the status to `true, ...` or `false, err`.

**The elegance of it:** resume is just *install a setjmp + start/restart the interpreter loop on another thread's stack*; yield is just *longjmp back*. No scheduler, no queues, no native-thread contexts — because Lua never uses the real OS stack for its call chain; everything lives in heap structures that can be frozen mid-flight and thawed later.

## 5. The yield bookkeeping details

- **`yieldable(L)` check.** `lua_yieldk` refuses to yield if the thread is the main thread ("attempt to yield from outside a coroutine") or if a non-yieldable C call is in progress ("attempt to yield across a C-call boundary"). The counter `nCcalls` is actually two 16-bit halves: C-call depth in the low half, *non-yieldable* call depth in the high half — `yieldable()` is literally `nCcalls & 0xffff0000 == 0`.
- **Yieldable C functions** register `k`; `lua_pcallk` additionally marks the frame `CIST_YPCALL` so `finishCcall` can re-invoke the error machinery correctly when the continuation runs.
- **Yield inside a debug hook** sets `CIST_HOOKYIELD` and is replayed by rewinding `savedpc` by one instruction.
- **To-be-closed variables** are tracked per-thread in `tbclist`; a coroutine that is closed (or that ends with open `<close>` variables) runs their `__close` handlers.

## 6. Status accounting (`lcorolib.c`)

`coroutine.status(co)` derives its answer from two facts — *is `co` the currently running thread?* and *what is `co->status`?*:

| Condition | Reported status |
|---|---|
| `co` is the thread currently executing | `running` |
| `co->status == LUA_YIELD` (suspended in a yield) | `suspended` |
| `co->status == LUA_OK`, not running, but has live frames (it's blocked inside its own `lua_resume` call, waiting for a child it resumed) | `normal` |
| `co->status == LUA_OK`, not running, no pending body/results (never started, or already returned) | `dead` |

Note the trick: `LUA_OK` is ambiguous between "normal" and "dead", and the call-frame state disambiguates. `coroutine.close` → `lua_closethread` → `luaE_resetthread` runs pending `__close` handlers, wipes the stack, resets `CallInfo`, and lands the thread in `dead`.

## 7. Memory management of threads

- Threads are ordinary `GCObject`s. `traversethread` (`lgc.c`) marks the stack values (only up to `top`, and only for live threads — dead threads' stacks are not traversed), the open upvalues, and the thread's metatable.
- Threads with **open upvalues** are chained in the global `twups` list so both `luaF_close` and the GC can find them across threads.
- Collection: `luaE_freethread` closes upvalues, frees the `CallInfo` array and the stack, unlinks the object. Dead threads are cheap to keep around — but they *are* collectable like any object.
- **Stack shrinkage:** `luaD_shrinkstack` runs during GC — if a coroutine once recursed deep but now uses < ¼ of its stack, the stack is reallocated down; same for `luaE_shrinkCI` trimming unused `CallInfo`s. Memory returned to the allocator through the single `lua_Alloc` choke point.

## 8. Nested resume chains

Coroutines compose: main thread resumes A, A resumes B. Each `lua_resume` installs its own `errorJmp` on *its* thread, so a `yield` inside B longjmps only to **A's** resume call — never to the main thread. Meanwhile:

- while B runs: B is `running`, A is `normal`, main is `normal`;
- the native C stack holds ~3 nested interpreter loops (one per active thread), which is exactly why nesting depth is capped by `LUAI_MAXCCALLS` — Lua's per-thread Lua stack can be a million slots deep, but the shared native C stack cannot.

## TL;DR

> A coroutine *is* a `lua_State`: a private value stack + `CallInfo` frame chain + saved `status`, allocated as a GC object, sharing the `global_State` heap. `resume` = move args onto its stack, install a setjmp, start (or replay via `unroll`/continuations) the interpreter loop on that stack. `yield` = set `status = LUA_YIELD` and `longjmp` back to the resume point. Suspension costs nothing but the untouched heap structures; there is no scheduler because *you* are the one calling `resume`.

# Lua Memory Model

Lua has no user-visible memory model in the C/C++ sense (no atomics, no data races in the language spec — the interpreter is single-threaded). What Lua *does* have is a very distinctive **object memory model**: how values live, are represented, shared, and reclaimed.

## 1. Values are not objects: the `TValue` layer

Every Lua value is a **`TValue`** (`lobject.h`): a union of raw data plus a type tag:

```c
typedef struct TValue {
  Value value_;   /* union: integer, number, GCObject*, boolean, ... */
  lu_byte tt_;    /* type tag + variant bits */
} TValue;
```

Key consequences:

- **Small values live inline.** Integers (`lua_Integer`, 64-bit), floats, booleans, `nil`, light userdata pointers are stored *directly in the stack slot*. Copying a `TValue` copies the whole value. There is zero heap allocation for `x = 42`.
- **Collectable objects live by pointer.** Strings, tables, functions, full userdata, threads are stored as `GCObject*` inside the union. Copying the `TValue` copies only the *pointer* — so **assignment, parameter passing, and table insertion never deep-copy**; they add a reference. Two variables holding "the same table" hold the same memory.
- **Tags encode variants.** The tag isn't just "number" — it distinguishes *integer* vs *float*, *short string* vs *long string*, *closed* vs *open* upvalue. `nil` is special-cased for speed; recent 5.4/5.5 builds also offer optional compact representations (tag-in-pointer "nan-boxing"-style variants) for 8-byte `TValue`s, but the classic layout is the one above.

So the model is: **a fixed-size tagged cell everywhere (stack slots, table entries, upvalues), where objects are reached by reference.** This is why Lua's assignment semantics are reference semantics for tables, value semantics for numbers.

## 2. Everything is allocated through one choke point

All heap memory goes through a single function pointer in `global_State`:

```c
void *l_alloc (void *ud, void *ptr, size_t osize, size_t nsize);
```

- Set via `lua_newstate`, overridable with `lua_Alloc` (`getallocf/setallocf` in `lstate.c`).
- Semantics are plain `realloc` semantics (`lmem.c`: `luaM_realloc_`, `luaM_growvector_`, `luaM_saferealloc_`).
- `NULL` on allocation failure raises `"not enough memory"` via `longjmp` — an ordinary Lua error the host can catch.
- This single choke point is what makes Lua embeddable: you can route *all* Lua memory into your own allocator, pool, or instrumented accounting (`lua_gc(L, LUA_GCCOUNT)` reports total bytes in use).

No per-type arenas, no hidden allocations: if you have the allocator, you see 100% of Lua's memory traffic.

## 3. The GCObject universe

Every collectable object begins with the same header (`CommonHeader`): a `next` pointer for GC lists, its type tag, and GC color bits:

```c
typedef struct GCObject {
  CommonHeader;
  /* union: TString, Udata, Closure, Table, Proto, UpVal, lua_State */
} GCObject;
```

Because every object starts with this header, the GC can walk everything polymorphically. The `global_State` maintains per-type linked lists (`allgc`, `finobj`, `fixedgc`, `tobefnz`, ...) that objects are linked into at birth — allocation is O(1) list-prepend.

The object types and their storage specifics:

### Strings (`lstring.c`) — interned and immutable
- All strings are **interned** in a hash table (`stringtable strt` in `global_State`): equal strings are the *same pointer*. String equality is a pointer comparison.
- **Short strings** (≤ 40 bytes, `LUAI_MAXSHORTLEN`) are interned and live forever until collected — they participate fully in the GC.
- **Long strings** are *not* interned (only hashed once for identity); creation is O(n) memcpy, comparison is memcmp. They're treated specially by the GC (cleared in bulk during atomic phase).
- Strings are never mutated. Every concatenation allocates a new string — the reason `table.concat` exists.
- Resizing the string table (`luaS_resize`) happens during GC/atomic phase, decoupled from allocation.

### Tables (`ltable.c`) — the only data structure
A table is split in two contiguous allocations (one `Table` struct + one node array):

- **Array part:** a dense C array of `TValue`s for keys `1..n` — cache-friendly, no hashing.
- **Hash part:** an array of `Node { TValue key; TValue value; Node *next; }` — open addressing with **linear chaining within buckets** (each node's `next` link).
- **Growth:** inserts trigger `luaH_resize`/`rehash`, which recomputes the array/hash split based on actual key density. Keys only usable as array part (positive integers, dense) migrate back into the array part — that's why `t[i]` after deleting `t[1]` may keep things in the hash part, and why `#t` is only defined for "sequences".
- **Deletions** are tombstones: the key is replaced by a special dead-key marker, the slot stays in the chain until rehash. (That's also why a table can shrink only on rehash/GC, not on `t[k] = nil`.)
- Empty tables are lazily backed by a **shared dummy node** (`dummynode`) — `t = {}` costs one small allocation.

### Functions (`lfunc.c`, `lvm.c`)
- **Lua closures** (`LClosure`): pointer to shared, immutable **`Proto`** (bytecode, constants, debug info) + an array of upvalue pointers. N closures over one function share one `Proto` — loaded chunks are memory-cheap to instantiate repeatedly.
- **C closures** (`CClosure`): a function pointer + an array of `TValue`s it can carry.

### Upvalues (`lupval.c`) — Lua's closure cell
- An upvalue points either **directly at a stack slot** (open) or, once the block exits, owns its own `TValue` (closed).
- Open upvalues of all threads are chained in the global `twups` list so `luaF_close` can find and close the ones pointing into a dying stack, and so the GC can traverse them.
- All closures created in one loop iteration *share* the same upvalue cell if they capture the same local — that's the semantics of the classic closure-counter example, and it's also memory-efficient (one cell, not N copies).

### Threads (`lstate.c`, `ldo.c`)
- Each `lua_State` owns: its **value stack** (grows by doubling via `luaD_reallocstack`, up to `LUAI_MAXSTACK`, typically 1,000,000 slots), an array of `CallInfo` frames (`L->ci`), and hook state.
- Stacks **shrink** opportunistically (during GC/`luaD_shrinkstack`) — a coroutine that once recursed deep doesn't keep that memory forever.
- `nCcalls` (5.4) also counts nested C calls + pending non-yieldable C calls to cap native stack overflow: "C stack overflow" is detected *before* your process dies.

### Full userdata vs light userdata
- **Full userdata**: GC-managed memory block with optional metatable and an env table — the way C libraries own memory in Lua.
- **Light userdata**: a raw pointer stored in a `TValue`; GC ignores it entirely — you keep it alive yourself.

## 4. The Garbage Collector (`lgc.c`) — the heart of the model

Lua 5.4 offers two GC kinds: **incremental** (default) and **generational**. Both are tracing collectors with the tri-color invariant.

### Incremental tri-color marking
Objects are white (unvisited), gray (reachable, children not yet scanned), black (fully scanned):

1. **Restart phase** — clear colors, gray the roots: main thread stacks, registry, `global_State` tables.
2. **Propagate phase** — gray objects' children get grayed, object turns black; interleaved with normal execution in small steps (`singlestep`).
3. **Barrier problem & barriers** — if the program mutates the heap while marking, the tri-color invariant can break (a white object linked from a black one would be collected while reachable). Lua solves it two ways:
   - **Forward barrier**: writing a white value into a black table turns the *value* gray (`luaC_barrier`). Used for tables, upvalues, userdata.
   - **Backward barrier**: writing into a *white/gray-ish* object grays the *container* instead (`luaC_barrierback`). Used for tables being scanned — cheaper because the table just re-enters the gray list.
   - New objects are born white, and colors are swapped between cycles (`otherwhite`), so freshly allocated objects survive without barriers.
4. **Atomic phase** — one indivisible big step: clear dead strings, sweep the string table, finalize weak tables, mark all threads, collect to-be-closed state. After this, all reachable objects are black and marks are valid again.
5. **Sweep phase** — walks the `allgc` list, whitens survivors, frees whites — also incremental.
6. **Finalization** — objects with `__gc` metatables are moved to `tobefnz`, called one per GC cycle, then truly freed (with a second `__gc` call for userdata if it was resurrected — the collector tracks `marked` bits to know).

### Generational mode (`lua_gc(L, LUA_GENMODE)`)
Objects are partitioned into "young" and "old" via the GC's list order and minor/major collections; a minor collection only scans young objects plus remembered (barrier-touched) old objects. Good for allocation-heavy workloads; tunable via `LUA_GCPARAM` knobs (`minormul`, `majormul`...).

### Pacing
The GC is *proportional*: it accumulates a **debt** proportional to the memory allocated since the last collection (`g->GCdebt`), and each interpreter step performs GC work to pay it down. `setpause` controls how much memory growth between cycles is tolerated; `setstepmul` how much work per step. **There is no hard guarantee when memory is freed** — only that it eventually is, and that total memory is bounded relative to live data.

### Weak tables and ephemerons
- `setmetatable(t, {__mode="k"})` / `"v"` / `"kv"`: entries whose *key* and/or *value* are only reachable through the table itself are removed.
- Implemented by segregating such tables into dedicated lists (`weak`, `allweak`, `ephemeron`) in `global_State`; ephemeron tables get a fixpoint iteration (removing one entry may make another value unreachable).
- A common real-world use: caches that don't leak (`__mode = "kv"`).

### Finalizers and the resurrection subtlety
- `__gc` runs **after** the object is already (conceptually) dead, but the object is *resurrected* for the duration of the finalizer — it's put back into `allgc` while the finalizer runs, then collected in a later cycle. Storing the object in a global inside `__gc` really does keep it alive (resurrection is legal).
- **To-be-closed variables** (5.4, `<close>`, `local x <close>`) are the deterministic counterpart: at scope exit, `__close` is called and the resource is released *immediately*, independent of the GC.

### Emergency collections
If an allocation fails, Lua runs an **emergency full collection** (`luaC_fullgc`) before raising "not enough memory" — sometimes memory is recoverable even when the allocator says no.

## 5. What the model means in practice

- **No value semantics for tables.** `t2 = t1` aliases; copies must be made explicitly. This is the single biggest semantic consequence of the memory model.
- **Strings behave as values** only because of interning + immutability — an implementation trick, not a rule about `TValue`s.
- **Anchoring from C.** The official safe anchor for a value created by a C function is the **registry** (`luaL_ref`/`luaL_unref`) or an upvalue; anything not reachable from a traversed root when the GC runs can be collected.
- **Memory profile.** A `TValue` is 16 bytes in the classic build; a small table ≈ 56 + 16·(2n) bytes; each interned short string pays ~40+ bytes once, then free on reuse. Long-running programs should watch string churn and prefer reusing tables, reusing `Proto`s (module-level functions), and weak caches.
- **Thread-local stacks, shared heap.** All coroutines share one `global_State` heap and one GC; a full collection pauses (in the atomic step) *all* threads. Memory is global; stacks are per-thread.
- **Concurrency caveat.** None of this is thread-safe. Sharing one `lua_State` across OS threads requires external locking; the standard solution is one state per thread plus message passing of serialized values (or libraries like Lanes that create cloned child states).

## TL;DR mental model

> Lua is a **tracing, incremental/generational, tri-color mark-and-sweep GC** over a heap of **tagged 16-byte cells**, where numbers live inline and everything else is a reference to a GCObject allocated through one user-swappable allocator; strings are interned and immutable; tables are array+hash hybrid structures; upvalues are reference cells that get "closed" onto the heap; and finalization exists in two flavors — nondeterministic (`__gc`) and deterministic (`<close>`).
