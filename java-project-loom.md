# How Project Loom (Virtual Threads) Works Under the Hood

Virtual threads (JEP 444, finalized in JDK 21; JEP 425/436 previews in 19/20) are *not* OS threads and not "green threads" in the classic 1.2-era sense. They're cooperative user-mode continuations scheduled onto real OS threads.

## 1. The three pieces

Every virtual thread is composed of:

1. **`java.lang.Thread`** — literally the same class. A flag marks it virtual (`Thread.isVirtual()`). All existing `Runnable`, `ThreadLocal`, `UncaughtExceptionHandler` code works unchanged.
2. **`jdk.internal.vm.Continuation`** — the actual suspension mechanism: a heap-allocated, resumable stack.
3. **A scheduler** — by default a `ForkJoinPool` in FIFO/async mode (`WorkQueue.asyncMode=true`), with parallelism = CPU cores and `maxPoolSize` default 256. Tunable via `jdk.virtualThreadScheduler.parallelism` / `.maxPoolSize`; replaceable via `Thread.ofVirtual().scheduler(...)`.

The OS threads that execute virtual threads are called **carrier threads** — they're just the ForkJoinPool's worker (platform) threads.

## 2. Continuations: the core mechanism

A `Continuation` owns the virtual thread's stack, stored on the heap in a special JVM object called a **`StackChunk`** (an `oop` with a special mark-word bit; GC knows about it natively).

### Mount / Unmount / Yield

- **Mount (`Continuation.run()` / `enter()`)**: copies stack frames from the `StackChunk` back onto the *carrier thread's* real machine stack and jumps to the suspension point. Execution continues as if nothing happened — local variables, monitors, return addresses all restored.
- **Unmount (`Continuation.yield()`)**: the reverse. It's a HotSpot **intrinsic** (`_continuation_yield`). The JVM performs a *freeze*: a stack walk from the current frame up to the continuation's entry frame, copying every frame's contents (locals, expression stack, monitors, interpreter state / compiled-frame layout, saved registers, frame pointer, the PC/BCI) into the `StackChunk`.
- After a freeze, `yield()` *returns normally* — but not into the resumed code; it returns to whoever called `run()`, i.e., the scheduler loop. The scheduler then just runs the next virtual thread. Context switch = one memcpy of a few KB in and out of the heap. No syscall, no kernel involvement.

### The "return barrier" (the subtle JIT part)

This is where it gets hairy for compiled (JIT) code. Suppose a C2-compiled method is frozen mid-execution and later thawed onto a *different* carrier. When that method eventually returns, it must **not** return to its old caller's stack — that stack no longer contains it (someone else's frames may be there).

Solution: when a compiled frame is frozen, its return address is patched to point at a **continuation-enter stub**. On thaw, the frame comes back with this special return address, so when the method returns normally it hits the barrier stub, which completes the continuation return cleanly instead of falling through into stale caller code. This is why frozen compiled frames must be stored with their metadata and why C2 has dedicated freeze/thaw support (`freeze_entry`, thaw paths "from compiled", `StackChunkFrameStream`).

### Interpreted vs compiled frames

- **Interpreted frames** are copied via the interpreter state (pointer into locals, monitor list, BCP, expression stack top).
- **Compiled frames** are copied with their register spill slots; on thaw, a compiled frame may need **deoptimization** (e.g., if the class was redefined while suspended) — the chunk stores enough info to reconstruct the interpreter state.
- Fast paths exist: C2 tries an inline freeze and a "last-frame" thaw (single frame → direct copy, skip the chunk round-trip).

### GC and StackChunks

GC handles chunks lazily: chunk frames are scanned like stack frames (via `StackChunkFrameStream`), oops inside are updated, and chunks can be "relaxed"/compacted over time. Because the stack lives in the heap, deep stacks just allocate bigger chunks — stacks grow dynamically (default cap ~1 MB, settable via `Thread.Builder.stackSize`), and GC pressure is roughly proportional to suspended-thread stack bytes, which is the real cost model of Loom (thousands of threads with shallow stacks = tiny footprint).

## 3. The scheduler loop

A carrier thread runs essentially this loop (`VirtualThread.runWorker`):

```
while (true) {
    vthread = queue.poll();          // FIFO ForkJoinPool submission queue
    vthread.continuation.enter();    // mount & run until yield/terminate
    // when enter() returns, the vthread parked or finished;
    // loop and pick up the next one
}
```

- `Thread.start()` doesn't create an OS thread — it just submits the virtual thread's continuation to the scheduler pool.
- `unpark()` pushes the continuation back into the run queue (with proper happens-before semantics like `LockSupport`).
- Carrier identity is deliberately hidden: `Thread.currentThread()` inside is always the virtual thread.

## 4. How "blocking" calls become non-blocking

The magic trick: **most blocking JDK operations were rewritten to park instead of block the carrier.**

- **Network I/O**: `SocketChannel` etc. are instrumented with a **poller** subsystem. When a virtual thread hits a blocking socket read, the JVM instead registers the fd with a small set of dedicated poller threads (backed by `kqueue`/`epoll` via NIO selectors), the thread parks (unmounts), and when the fd is ready the poller unparks it. `ServerSocket.accept`, `Socket.getInputStream().read()`, TLS handshakes — all covered.
- **Timers**: `Thread.sleep`, `LockSupport.parkNanos`, timeouts go through the scheduler's internal timer queue — the carrier is released immediately.
- **`java.util.concurrent` locks** already used `LockSupport`, so they park for free.
- **`Object.wait()`** was re-implemented internally to park-based machinery instead of blocking the carrier.
- **Compensation**: if a carrier *is* genuinely stuck (see pinning, or blocking file I/O on the default filesystem, which is inherently non-non-blockable), the scheduler temporarily adds carrier threads (up to `maxPoolSize`) so CPU parallelism isn't lost.

## 5. Pinning — the historical wart and its fix

Pre-JDK 24, a virtual thread **pinned** its carrier (couldn't unmount) when:

- It was inside a `synchronized` block/method — monitor ownership was tied to a stack-resident lock record on the carrier's frame, so moving the stack would break the lock.
- It was blocked in a **native (JNI) frame** — native code holds raw pointers into the stack.
- `Object.wait()` for similar reasons.

**JEP 491 (JDK 24)** fixed monitors: lock state for monitors held by virtual threads is now tracked in per-object monitor lists independent of any stack, so `synchronized` no longer pins, and blocking on a monitor properly parks/unmounts. The remaining unavoidable pinning is native frames (JNI critical regions, etc.). Diagnostic pre-24: `-Djdk.tracePinnedThreads=full`, plus JFR events `jdk.VirtualThreadPinned` and `jdk.VirtualThreadSubmitFailed`.

## 6. Runtime integration

- **Stack traces / `StackWalker`**: the JVM can walk an *unmounted* thread by iterating the `StackChunk` frames directly — no mount needed. Debuggers and JVMTI got virtual-thread-aware support (`ThreadStart/End`, `VirtualThreadMount/Unmount` events in JFR).
- **ThreadLocals**: stored in a map referenced by the `Thread` object on the heap (they must live in the heap anyway, since the stack moves between carriers). That's also why Loom's guidance is "don't pool virtual threads, and don't use thread-local caches at scale."
- **Nested continuations** are supported via `ContinuationScope` — a yield only unwinds to the innermost matching scope.
- **No new memory model, no preemption**: switching happens only at explicit yield/park points, so a CPU-bound loop inside a virtual thread monopolizes its carrier — CPU-bound work still belongs on platform threads.

## 7. The one-sentence summary

A virtual thread is a heap-resident, freezable stack (`Continuation` + `StackChunk`); `yield()` copies the machine stack into the heap and hands the OS thread back to a FIFO `ForkJoinPool`; every JDK "blocking" API that matters was rewired to park (unmount) instead of block, using epoll/kqueue pollers for sockets and timer queues for sleeps — so millions of cheap threads multiplex over a handful of kernel threads with pure user-space context switches.
