# How Thread Pools Work in Java

A thread pool is a set of pre-created, reusable worker threads that execute submitted tasks. Instead of creating a new thread per task (expensive: ~1MB stack each, slow creation, unbounded resource usage), you submit tasks to a pool that manages a fixed set of threads.

## Core Class: `ThreadPoolExecutor`

Everything in Java's classic thread pool machinery revolves around this one class:

```java
public ThreadPoolExecutor(
    int corePoolSize,          // min threads kept alive
    int maximumPoolSize,       // hard cap on threads
    long keepAliveTime,        // idle time before extra threads die
    TimeUnit unit,             // unit for keepAliveTime
    BlockingQueue<Runnable> workQueue,  // where tasks wait
    ThreadFactory threadFactory,        // how threads are created
    RejectedExecutionHandler handler    // what to do when saturated
)
```

## Task Submission Flow

When you call `execute(task)`, `ThreadPoolExecutor` follows this exact decision order (from `java.util.concurrent.ThreadPoolExecutor#execute`):

```
1. If running threads < corePoolSize
       → create a NEW thread, give it the task directly
2. Else, try to enqueue the task into workQueue
       → if enqueue succeeds, done (a worker will pick it up)
3. If queue is FULL:
       → if running threads < maximumPoolSize, create a new (non-core) thread
       → else, the pool is saturated → invoke the RejectedExecutionHandler
```

Note the counterintuitive part: **the pool grows to `maximumPoolSize` only AFTER the queue fills up**, not before. This is why an unbounded queue (like `LinkedBlockingQueue` in the "cached" style) means `maximumPoolSize` is never reached.

## Worker Lifecycle

Each thread in the pool is a `Worker` (an inner class extending `AbstractQueuedSynchronizer` implementing `Runnable`):

1. Worker thread runs a loop: `getTask()` → pulls from `workQueue` (blocking `queue.take()`)
2. Executes `task.run()` in **its own thread** (not a new one)
3. Loops back for the next task
4. If `getTask()` returns `null` (timeout exceeded and thread count > corePoolSize, or shutdown called), the worker exits

This reuse is the whole point — thread creation/disposal happens rarely; task handoff is just a queue operation.

## Key Parameters Explained

| Parameter | Meaning |
|---|---|
| `corePoolSize` | Threads kept alive even when idle (unless `allowCoreThreadTimeOut(true)`) |
| `maximumPoolSize` | Absolute max threads. Queue must be full before exceeding core |
| `keepAliveTime` | How long a non-core idle thread waits before terminating |
| `workQueue` | `LinkedBlockingQueue` (unbounded), `ArrayBlockingQueue(n)` (bounded), `SynchronousQueue` (0 capacity — hands off directly) |
| `threadFactory` | Names threads, sets daemon status, uncaught exception handler |
| `handler` | Saturation policy |

## Rejection Policies (when saturated)

- `AbortPolicy` (default) — throws `RejectedExecutionException`
- `CallerRunsPolicy` — the **submitting thread** runs the task itself (natural backpressure/throttling)
- `DiscardPolicy` — silently drops the task
- `DiscardOldestPolicy` — drops the oldest queued task, retries

## The `Executors` Factory Methods

```java
Executors.newFixedThreadPool(n)      // core = max = n, unbounded LinkedBlockingQueue
Executors.newCachedThreadPool()      // core=0, max=Integer.MAX_VALUE, SynchronousQueue (60s keepalive)
Executors.newSingleThreadExecutor()  // one worker, unbounded queue
Executors.newScheduledThreadPool(n)  // delayed/periodic tasks, uses a DelayedWorkQueue
```

⚠️ These are discouraged in production code (Alibaba/IDE linters flag them): `newFixedThreadPool` and `newSingleThreadExecutor` can cause **OOM via unbounded queues**; `newCachedThreadPool` can cause **OOM via unbounded threads**. Prefer constructing `ThreadPoolExecutor` directly with a bounded queue.

## ForkJoinPool (work-stealing)

`ForkJoinPool` (used by parallel streams, `CompletableFuture`'s common pool) works differently:

- Each worker thread has its own **deque** of tasks
- Workers pop from the **head** of their own deque (LIFO for cache locality)
- Idle workers **steal** from the **tail** of other workers' deques
- Ideal for recursive divide-and-conquer tasks (`RecursiveTask`/`RecursiveAction`)

This reduces contention compared to one shared queue.

## Sizing Heuristics

- **CPU-bound tasks**: threads ≈ `Runtime.getRuntime().availableProcessors()` (or +1)
- **I/O-bound tasks**: threads ≈ `cores * (1 + waitTime/computeTime)` — often 2–10x cores
- Always use a **bounded queue** + a saturation policy that provides backpressure

## Modern Alternative: Virtual Threads (Java 21+)

For I/O-heavy workloads, `Executors.newVirtualThreadPerTaskExecutor()` creates a lightweight virtual thread per task (no pooling needed — virtual threads are cheap, ~KB of memory, mounted/unmounted on carrier threads). Thread pools remain the right tool for CPU-bound work; virtual threads replace pools for high-concurrency I/O.

## TL;DR

Pool = **fixed set of worker threads + blocking queue + admission policy**. `execute()` either spawns a worker, enqueues, spawns an extra worker, or rejects. Workers loop forever pulling tasks from the queue, so thread creation cost is amortized and you get controlled concurrency, queueing, and backpressure.
