# How `ThreadExecutor` Works in Java (Deep Dive)

There's no class literally named `ThreadExecutor` — the core class is **`java.util.concurrent.ThreadPoolExecutor`**, plus the facade **`Executors`** factory. Here's how the whole machinery works internally.

---

## 1. The Interface Hierarchy

```
Executor                  // single method: execute(Runnable)
  └── ExecutorService     // lifecycle + Future support (submit, shutdown, invokeAll...)
        └── AbstractExecutorService   // skeleton impl of submit/invokeAll via newTaskFor
              └── ThreadPoolExecutor  // the real engine
```

- **`Executor`** — decouples task *submission* from task *execution*. You hand over a `Runnable`, not caring which thread runs it.
- **`ExecutorService`** — adds `submit()` (returns `Future`), `shutdown()`, `awaitTermination()`, `invokeAll()`.
- **`AbstractExecutorService`** — implements `submit()` by wrapping `Runnable`/`Callable` into a `RunnableFuture` (`FutureTask`) and calling `execute()`.

---

## 2. The Three Pillars of `ThreadPoolExecutor`

```java
public ThreadPoolExecutor(int corePoolSize,
                          int maximumPoolSize,
                          long keepAliveTime,
                          TimeUnit unit,
                          BlockingQueue<Runnable> workQueue,
                          ThreadFactory threadFactory,
                          RejectedExecutionHandler handler)
```

1. **`corePoolSize`** — threads kept alive even when idle (unless `allowCoreThreadTimeOut(true)` is set).
2. **`maximumPoolSize`** — hard ceiling on threads.
3. **`workQueue`** — a `BlockingQueue` holding tasks waiting for a thread.

### The queue choice determines behavior (this is the subtle part):

| Queue | Behavior |
|---|---|
| `SynchronousQueue` (used by `CachedThreadPool`) | No capacity → a new thread is spawned for almost every task while under max size |
| Unbounded `LinkedBlockingQueue` (used by `FixedThreadPool`) | Max pool size & rejection handler **never take effect** — queue grows forever |
| Bounded `ArrayBlockingQueue(n)` | Queue fills first → *then* extra threads are added up to max → *then* rejection |

---

## 3. The `execute()` Flow — the Heart of It

This is roughly the actual algorithm in `ThreadPoolExecutor.execute()`:

```java
public void execute(Runnable command) {
    int c = ctl.get();
    // 1. If worker count < corePoolSize → try to add a core thread
    if (workerCountOf(c) < corePoolSize) {
        if (addWorker(command, true)) return;
        c = ctl.get();
    }
    // 2. Offer the task to the queue
    if (isRunning(c) && workQueue.offer(command)) {
        int recheck = ctl.get();
        if (!isRunning(recheck) && remove(command))
            reject(command);                    // pool shut down meanwhile
        else if (workerCountOf(recheck) == 0)
            addWorker(null, false);             // guard against all-workers-dead
    }
    // 3. Queue full → try to add a non-core (overflow) thread
    else if (!addWorker(command, false))
        // 4. Max threads + full queue → reject
        reject(command);
}
```

So the ordering is: **core thread → queue → extra thread → reject**. Many people assume "new threads are created before queueing" — that's wrong; the queue is consulted *before* spawning non-core threads.

---

## 4. `Worker` and the `ctl` Variable — Internal State

### `ctl` — packed into a single `AtomicInteger`

```java
private final AtomicInteger ctl = new AtomicInteger(ctlOf(RUNNING, 0));
// high 3 bits  = run state (RUNNING, SHUTDOWN, STOP, TIDYING, TERMINATED)
// low 29 bits  = worker count
```

States:
- **RUNNING** (`-1`): accepts new tasks, processes queue
- **SHUTDOWN** (`0`): no new tasks, drains the queue (`shutdown()`)
- **STOP** (`1`): no new tasks, discards queue, interrupts running tasks (`shutdownNow()`)
- **TIDYING**: all workers gone, queue empty; `terminated()` hook runs
- **TERMINATED**: done

The packing trick avoids a lock for "state + count" checks; transitions still use an internal `mainLock` (a plain `ReentrantLock`) for structural changes to the worker set.

### The `Worker` class

```java
private final class Worker extends AbstractQueuedSynchronizer implements Runnable {
    final Thread thread;        // created via threadFactory.newThread(this)
    Runnable firstTask;
    volatile long completedTasks;
}
```

Each `Worker` is both:
- A **lock (AQS)** — the pool never locks the worker itself while it runs; instead `shutdown()` uses the *tryLock* to interrupt only *idle* workers (a running worker can't acquire its own lock, so `interruptIdleWorkers` skips it).
- A **Runnable wrapper** — its `run()` loops pulling tasks:

```java
final void runWorker(Worker w) {
    Runnable task = w.firstTask;
    w.firstTask = null;
    while (task != null || (task = getTask()) != null) {
        w.lock();                        // signal "I'm busy"
        try { runTask(task); ... }       // beforeExecute / task.run / afterExecute hooks
        finally { task = null; w.unlock(); w.completedTasks++; }
    }
    // loop exited → worker times out or pool is stopping
    processWorkerExit(w, completedAbruptly);
}
```

**This is why threads "don't die":** the worker thread never ends while there's work — it loops on `getTask()`, which blocks on `workQueue.take()` (core threads) or `poll(keepAliveTime)` (non-core threads, which exit on timeout).

### `getTask()` — where keepAliveTime lives

```java
private Runnable getTask() {
    boolean timedOut = false;
    for (;;) {
        int c = ctl.get();
        // If pool is STOPping or queue is empty during SHUTDOWN → worker exits (null)
        int wc = workerCountOf(c);
        boolean timed = allowCoreThreadTimeOut || wc > corePoolSize;
        if (timed)
            r = workQueue.poll(keepAliveTime, TimeUnit.NANOSECONDS); // idle thread dies here
        else
            r = workQueue.take();                                     // blocks forever
        ...
    }
}
```

When a non-core thread's `poll` times out, it returns `null`, `runWorker`'s loop exits, and `processWorkerExit` decrements the worker count — the thread dies, shrinking the pool back toward `corePoolSize`.

---

## 5. Rejection Policies (`RejectedExecutionHandler`)

When `execute()` fails at step 4 (state != RUNNING, or at max threads with a full queue), the configured handler is invoked with the pool + task:

| Policy | Behavior |
|---|---|
| `AbortPolicy` (default) | Throws `RejectedExecutionException` |
| `CallerRunsPolicy` | Runs the task **synchronously in the submitting thread** → natural backpressure/throttling |
| `DiscardPolicy` | Silently drops the task |
| `DiscardOldestPolicy` | Drops the *head* of the queue (oldest) and retries execute |

You can write your own handler — e.g., log, block until space is available, or persist to disk.

---

## 6. Lifecycle & Shutdown

- **`shutdown()`** — sets state to SHUTDOWN; interrupts only *idle* workers; queued tasks still run. Graceful.
- **`shutdownNow()`** — sets STOP; interrupts **all** workers; drains the queue and returns the list of never-run tasks. `Runnable.run()` that ignores interrupts will keep running — interruption is cooperative.
- **`awaitTermination(timeout)`** — blocks until TERMINATED or timeout.
- **`terminated()`** — a protected hook invoked exactly once when the pool reaches TIDYING (useful for cleanup/monitoring).

The termination sequence is driven by `tryTerminate()`, which is attempted opportunistically after worker exits, task removals, and shutdown calls.

---

## 7. Supporting Machinery

- **`ThreadFactory`** — controls thread naming, daemon status, priority, `UncaughtExceptionHandler`. Naming threads is critical for debugging thread dumps.
- **`beforeExecute` / `afterExecute` hooks** — protected methods to add per-task instrumentation (e.g., thread-local context propagation, timing).
- **`ForkJoinPool`** — a *different* executor design: work-stealing, each thread has its own deque, idle threads steal from others' tails. `ForkJoinPool.commonPool()` backs parallel streams. Best for recursive divide-and-conquer and mostly CPU-bound work with tiny tasks.
- **`CompletableFuture`** — on Java 9+, `delayedExecutor`, and its default async pool is `ForkJoinPool.commonPool()` (not a `ThreadPoolExecutor`).
- **Virtual threads (Java 21)** — `Executors.newVirtualThreadPerTaskExecutor()` abandons pooling entirely: an OS-cheap thread per task, mounted/unmounted on carrier threads. For I/O-heavy workloads this is often better than any classic pool.

---

## 8. What the `Executors` Factory Methods Build

```java
newFixedThreadPool(n)      → core=max=n, unbounded LinkedBlockingQueue   // risk: OOM on backlog
newCachedThreadPool()      → core=0, max=Integer.MAX_VALUE, SynchronousQueue, 60s keepAlive // risk: unbounded threads
newSingleThreadExecutor()  → 1 thread, unbounded queue, guarantees ordering
newScheduledThreadPool(n)  → actually a ScheduledThreadPoolExecutor (DelayedWorkQueue, can schedule at fixed rate/delay)
newWorkStealingPool()      → ForkJoinPool
```

The classic production recommendation: **use bounded queues + explicit `maximumPoolSize` + a sensible rejection policy** (often `CallerRunsPolicy`), and size `corePoolSize` to CPU cores for CPU-bound work (roughly `Ncpus`) or higher for I/O-bound work.

---

## TL;DR

A `ThreadPoolExecutor` is: a packed state/count `AtomicInteger`, a `BlockingQueue` of tasks, and a set of `Worker` objects — each one a long-lived thread that loops `getTask()` → `task.run()` until the queue is empty and the pool is shutting down (or its keep-alive expires). Submission follows *core-thread → queue → extra-thread → reject*, and the entire "pool" illusion comes from worker threads never terminating while work remains.

---
---

# Chapter 2: How `ForkJoinPool` Works in Java (Deep Dive)

`ForkJoinPool` (Java 7+, `java.util.concurrent.ForkJoinPool`) is a fundamentally different executor design from `ThreadPoolExecutor`. Instead of a shared queue + waiting workers, it uses **work stealing**: every worker thread has its *own private deque*, and idle threads steal work from busy ones.

---

## 1. Why a Different Design?

`ThreadPoolExecutor` assumes:
- Tasks are independent, coarse-grained, mostly I/O or request-handling.
- Workers pull from **one shared queue** → heavy contention under parallelism.

Fork/Join workloads are the opposite: **recursive divide-and-conquer**, huge numbers of **tiny CPU-bound tasks**, where tasks *spawn subtasks* (`fork()`) and *wait for their results* (`join()`). A shared queue would collapse under that: contention + the "waiting parent blocks a pool thread" problem. ForkJoinPool solves both:

- Each worker pushes/pops on its **own deque** → almost no contention.
- When a task calls `join()`, the worker **doesn't block** — it goes and steals other tasks, so a *waiting parent becomes a useful worker*.

---

## 2. The Core Concepts

### `ForkJoinTask<V>`

Abstract base for tasks. Key operations:

```java
task.fork();       // asynchronously schedule: push onto the worker's own deque
task.join();       // wait for result — but without blocking if avoidable
task.invoke();     // fork + join in one
ForkJoinTask.invokeAll(t1, t2, ...); // fork all, then join all in order
```

Concrete flavors: `RecursiveAction` (no result, `compute()` returns void), `RecursiveTask<V>` (returns a result), `CountedCompleter` (generalized, completion-triggered — used by the JDK internally, e.g. in `CompletableFuture` and stream operations).

Canonical pattern:

```java
class SumTask extends RecursiveTask<Long> {
    static final int THRESHOLD = 10_000; // "grain size"
    long[] arr; int lo, hi;

    protected Long compute() {
        if (hi - lo <= THRESHOLD) {          // small enough → do it inline
            long s = 0;
            for (int i = lo; i < hi; i++) s += arr[i];
            return s;
        }
        int mid = (lo + hi) >>> 1;           // split
        SumTask left  = new SumTask(arr, lo, mid);
        SumTask right = new SumTask(arr, mid, hi);
        left.fork();                         // push left to own deque
        return right.compute() + left.join(); // compute right INLINE, then join left
    }
}
```

The **threshold** is critical: too small → task-management overhead dominates; too large → not enough parallelism. Rules of thumb: thousands of ops per task; split until `N / (parallelism * 8)` size tasks remain.

**Important:** the sequential half (`right.compute()`) runs *inline on the same thread, no fork*. Forking both halves doubles queue traffic for no benefit.

---

## 3. The Central Data Structure: `WorkQueue`

The heart of the implementation. Each worker owns a `WorkQueue` — a **circular array deque**:

```
        array (base … top)
base →  [t0][t1][t2][t3][t4]  ← top
```

- **`push` / `pop` operate at `top`** — done by the owning worker only, using ordinary (non-atomic, unsynchronized!) array writes when uncontended. `top` is a plain `int` field because only the owner touches it.
- **`poll` (stealing) operates at `base`** — done by *other* threads, using CAS on the `base` index.

This split is the whole trick: **the owner competes only with thieves, and they work on opposite ends.** Under contention they meet in the middle, and the deque can even be temporarily empty while both sides race — handled via phase/spin protocols (`tryLock` on the queue, `LOCKED` state) to arbitrate.

The deque **doubles/grows** when the owner pushes (like `ArrayDeque`), and shrinks on steals when less than half used.

Key fields:

```java
static final class WorkQueue {
    volatile int phase;          // owned/lock state + "active" bit
    int scanState;               // versioned, even=scanning odd=queued, detects stale scans
    int nsteals;
    int id;                      // pool index; negative for external/submission queues
    volatile int source;         // source queue id while scanning
    volatile int base;           // bottom of deque (stolen from here) — volatile!
    int top;                     // top of deque (owner pushes here) — NOT volatile (owner-only)
    ForkJoinTask<?>[] array;
    final ForkJoinWorkerThread owner;
}
```

Note `top` is **not volatile** — safe because only the owner writes it, and thieves read `base` (volatile) and validate via the versioned `phase`/`scanState` mechanism rather than trusting `top`.

---

## 4. Pool Layout: `WorkQueue[] workQueues`

The pool holds an array of all queues, even-indexed:

- **Even indices:** shared *submission* queues (`submit()` / `execute()` enqueue here; also external threads calling `fork()` outside the pool — "external pushes"). These have `null` owner and are protected by a lock (`qlock`).
- **Odd indices:** one queue per `ForkJoinWorkerThread`, i.e. per worker.

The array is sized to a power of two and workers try to occupy **even-adjacent (odd) slots hashed by their probe value** to spread out.

There are two operating modes:

- **asyncMode = false (default):** LIFO for the owner, FIFO steals — good for *join-heavy recursive* tasks (stealing the oldest/largest task makes thieves do big chunks, and the owner finishing newest-first minimizes joins).
- **asyncMode = true:** FIFO for everyone — better for non-joinable, event-style tasks ("async monolith" mode).

---

## 5. Worker Lifecycle: `ForkJoinWorkerThread` and the Run Loop

Each worker is a `ForkJoinWorkerThread` with an inherited `UncaughtExceptionHandler` (pool tracks exceptions) and thread-local `probe` (a hash seed for spreading).

The essence of `ForkJoinPool.runWorker`:

```java
final void runWorker(WorkQueue w) {
    w.config |= SRC; // ... setup
    if (w.execLocalTasks())            // drain own deque first
        ...
    for (;;) {                         // outer loop: scan for work
        if ((task = scan(w, r)) != null) {   // r = pseudo-random probe
            w.execTask(task);                // found → execute
            continue;
        }
        if (!awaitWork(w)) break;            // none → try to park/block
    }
}
```

### Scanning (`scan()`)

- The worker picks a **random starting index** (`r`) and **sweeps the whole `workQueues` array** probing each queue's `base` for a stealable task.
- It CAS-steals from the first non-empty queue found (via `tryPoll`), bumping the queue owner's `nsteals`.
- Randomized start + full sweep = fairness without coordination (similar idea to `LongAdder` striping / `ThreadLocalRandom`).
- If nothing found in a full sweep, it updates its `scanState` (odd, versioned) and moves toward parking.

### `join()` — the part that makes it all work

When a worker's task calls `join()`, `ForkJoinTask.awaitDone` (via `ForkJoinPool.joinTask`) tries, in order:

1. **Try to run the joined task itself** if it's on the top of *my* deque.
2. **Try to find the joined task** and steal it *from whoever has it* (e.g. it was stolen, or it sits in a submission queue). This can be done **helping** (for internal joins: pop/poll it out and run it) — the joiner executes the very task it's waiting on.
3. **Compensate:** if it can't help, the worker may park — and the pool tries to ensure enough threads remain active by **creating a compensation thread** (for managed blockers) so parallelism doesn't silently drop.
4. Only then actually **block** (`LockSupport.park`) on `Phaser`-like internal signaling.

So "join" is not `wait()` — it's *steal-your-own-subtask-or-help-others* first. This is why fork/join doesn't deadlock the way one-thread-per-recursive-call would.

`CountedCompleter` generalizes this: instead of joining each child, you maintain a pending-count (`tryComplete()`), letting one `join()` cover N subtasks — the JDK's internal parallel ops (e.g., `Arrays.parallelSort`, `CompletableFuture` composition) use it.

---

## 6. Blocking, Parking, and `ManagedBlocker`

Idle workers decrement the `ctl` field (see below) and park via `LockSupport`. Wake-up happens on pushes (a pusher notifies a plausible victim) and on `signalWork`.

For **blocking I/O inside a ForkJoin task**, use:

```java
ManagedBlocker blocker = ...
ForkJoinPool.managedBlock(blocker);
```

Before blocking, it *compensates* — may spin up an extra thread so the effective parallelism is preserved while one thread is blocked. Without this, blocking calls just silently shrink your parallelism. (Java 21 note: virtual threads make this mostly obsolete for I/O workloads.)

---

## 7. `ctl` — the Pool's Packed State (like ThreadPoolExecutor's, but bigger)

```java
private final AtomicLong ctl; // 64 bits packed:
//  AC (16 bits): number of active (non-idle) workers minus target parallelism
//  TC (16 bits): total created workers minus target parallelism
//  ID (32 bits): signal word — encodes which idle worker/thread to wake
```

- If `AC < 0` → fewer active workers than needed → `signalWork` wakes/creates.
- `TC < 0` → fewer total workers than needed → create one via `threadFactory`.
- `ID` identifies a parked worker to resume (queued waiters are threaded through their `scanState`).

All liveness decisions (create thread? wake which one?) are made with CAS on this single `AtomicLong` — no global lock.

---

## 8. The `commonPool()`

`ForkJoinPool.commonPool()` is a **static shared instance** used by:

- parallel streams (`list.parallelStream()`)
- `Arrays.parallelSort`
- `CompletableFuture` async methods without an explicit executor
- `ForkJoinTask.fork()` outside any pool

Properties:
- Parallelism = `availableProcessors - 1` (so the caller's thread effectively counts as one participant — with `parallelism=3` and 4 CPUs, the caller thread that submits and joins counts as the 4th).
- Threads are **daemon**, created lazily, and die after ~60s idle (keepAlive like a cached pool).
- Don't use it for blocking I/O — you'll starve parallel streams and other framework users sharing it. Pass your own executor to `CompletableFuture.supplyAsync(fn, executor)` for that.
- Configurable via system properties: `java.util.concurrent.ForkJoinPool.common.parallelism`, `.threadFactory`, `.exceptionHandler`.

---

## 9. `ForkJoinPool` vs `ThreadPoolExecutor` — Side by Side

| Aspect | `ThreadPoolExecutor` | `ForkJoinPool` |
|---|---|---|
| Queues | One shared `BlockingQueue` | Per-worker deques + shared submission queues |
| Work distribution | All workers race on one queue | Owner pops own deque; thieves poll others' `base` |
| Contention | High (single queue) | Near zero (LIFO local, FIFO steal at opposite ends) |
| Task granularity | Coarse, few tasks | Fine, huge numbers of tiny tasks |
| Tasks spawn subtasks | No (nested `execute` just queues) | Yes — `fork()/join()` with non-blocking join |
| Join semantics | Blocking `Future.get()` | Helping/stealing + compensation, rarely blocks |
| Steal order | — | FIFO from victim's `base` (oldest/largest first) |
| Local pop order | — | LIFO from `top` (default mode: better cache locality, minimal joins) |
| Blocking I/O | Acceptable (small pools) | Needs `ManagedBlocker` (or virtual threads) |
| Suits | Web requests, scheduled jobs, mixed I/O | Recursive divide-and-conquer, CPU-bound parallelism |
| Global state | `AtomicInteger ctl` | `AtomicLong ctl` + versioned per-queue `phase/scanState` |

---

## 10. Practical Guidance

- **Use ForkJoinPool for:** CPU-bound recursive problems — parallel sort, tree/graph traversal, matrix/image processing, aggregate reductions. Size the threshold to yield ~`2–8 * parallelism` tasks minimum.
- **Use ThreadPoolExecutor for:** independent request-style or I/O tasks with bounded queues.
- **Never block the common pool** (I/O, locks, sleeps) — starves parallel streams and `CompletableFuture`.
- `getParallelism()`, `getStealCount()`, `getQueuedTaskCount()` — the main monitoring hooks.
- Java 21+: for I/O-bound work, prefer `Executors.newVirtualThreadPerTaskExecutor()`; for CPU-bound work, ForkJoinPool remains the right tool.

---

## TL;DR

A `ForkJoinPool` is a set of workers, each owning a lock-free deque: the owner pushes/pops new tasks at its `top`, idle workers CAS-steal from others' `base`. `fork()` pushes a subtask onto the caller's own deque; `join()` doesn't sleep — the worker tries to execute the awaited subtask itself (helping), steals it if needed, or parks only after the pool ensures compensating parallelism via `ctl`. Randomized scanning spreads thieves across the queue array, and the shared `commonPool()` quietly powers parallel streams and `CompletableFuture`. It exists because fork/join workloads — millions of tiny, recursively spawned, mutually waiting tasks — would kill a shared-queue executor with contention and blocked-parent deadlock.
