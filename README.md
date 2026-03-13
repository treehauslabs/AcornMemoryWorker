# AcornMemoryWorker

An in-memory content-addressable storage worker for Swift, with nanosecond-scale synchronous lookups and actor-based protocol conformance for [Acorn](../Acorn) storage chains.

```swift
let worker = MemoryCASWorker()

let data = Data("hello, acorn".utf8)
let cid = ContentIdentifier(for: data)

worker.syncStore(cid: cid, data: data)
worker.syncGet(cid: cid)                      // Data("hello, acorn") — 28ns
```

## Why This Exists

Content-addressable storage is a powerful primitive: store once, retrieve by hash, never worry about naming collisions or stale references. But a single storage layer forces a tradeoff between speed and durability.

Acorn solves this by chaining workers from *near* (fast, limited) to *far* (slow, complete). **AcornMemoryWorker** is the near end of that chain: a lock-protected dictionary store running entirely in process memory.

```
  near ←――――――――――――――――――――――――――――――――――→ far

  ┌──────────────┐    ┌──────────┐    ┌──────────┐
  │ MemoryCAS    │◄──►│ DiskCAS  │◄──►│ Network  │
  │ Worker       │    │ Worker   │    │ Worker   │
  └──────────────┘    └──────────┘    └──────────┘
        fast               ↕              slow
      volatile          durable         complete
```

## Requirements

- Swift 6.0+
- macOS 13+ / iOS 16+
- [Acorn](../Acorn) package

## Installation

```swift
.package(url: "https://github.com/treehauslabs/AcornMemoryWorker.git", from: "1.0.0"),
```

Then add to your target:

```swift
.target(name: "YourTarget", dependencies: ["AcornMemoryWorker"])
```

## Usage

### Synchronous API (hot path)

For maximum throughput, use the `sync*` methods directly. These bypass the actor executor and go straight through an `os_unfair_lock`:

```swift
import AcornMemoryWorker
import Acorn

let worker = MemoryCASWorker()

let data = Data("sensor-reading-42".utf8)
let cid = ContentIdentifier(for: data)

worker.syncStore(cid: cid, data: data)          // 142ns
worker.syncGet(cid: cid)                         // 28ns
worker.syncHas(cid: cid)                         // 11ns
worker.syncDelete(cid: cid)                      // 78ns
```

### Async API (protocol conformance & chaining)

The actor-based API conforms to `AcornCASWorker` for use in storage chains:

```swift
await worker.storeLocal(cid: cid, data: data)
await worker.get(cid: cid)
await worker.has(cid: cid)
```

These delegate to the same lock-protected storage internally, but pay ~7us of actor hop overhead per call.

### Capacity-bounded cache with LFU eviction

```swift
let worker = MemoryCASWorker(
    capacity: 10_000,
    halfLife: .seconds(300),
    sampleSize: 5
)
```

### Size-bounded cache with maxBytes eviction

```swift
let worker = MemoryCASWorker(maxBytes: 50_000_000)    // 50 MB
```

### Observability

```swift
let m = await worker.metrics
print("hits: \(m.hits), misses: \(m.misses), evictions: \(m.evictions)")
print("total bytes in memory: \(await worker.totalBytes)")
```

### Chaining with other workers

```swift
let memory = MemoryCASWorker(capacity: 1_000)
let disk = try DiskCASWorker(directory: cacheDir, capacity: 50_000)

let chain = await CompositeCASWorker(
    workers: ["memory": memory, "disk": disk],
    order: ["memory", "disk"]
)

let data = await chain.get(cid: someCID)
```

## API

### `MemoryCASWorker`

| Method | Description |
|--------|-------------|
| `init(capacity:maxBytes:halfLife:sampleSize:timeout:)` | Create a worker with optional bounded eviction. |
| **Sync API** | |
| `syncHas(cid:) -> Bool` | Lock-based existence check. ~3-11ns. |
| `syncGet(cid:) -> Data?` | Lock-based read. ~6-28ns. |
| `syncStore(cid:data:)` | Lock-based write with optional eviction. ~142ns. |
| `syncDelete(cid:)` | Lock-based delete. ~78ns. |
| **Actor API** | |
| `has(cid:) -> Bool` | Actor-isolated existence check. |
| `getLocal(cid:) async -> Data?` | Actor-isolated read. |
| `storeLocal(cid:data:) async` | Actor-isolated write. |
| `delete(cid:)` | Actor-isolated delete. |
| `get(cid:) -> Data?` | Protocol default: checks near first, then local. |
| `store(cid:data:)` | Protocol default: stores locally, then propagates. |
| `metrics -> CASMetrics` | Hits, misses, stores, evictions, deletions. |
| `totalBytes -> Int` | Current total bytes in memory (O(1)). |

## Design

- **Dual API** — the actor methods satisfy `AcornCASWorker` protocol conformance for chaining. The `nonisolated` sync methods bypass the actor executor entirely, going through `OSAllocatedUnfairLock` for nanosecond-scale access.
- **Single lock-protected state** — all mutable state lives in a single `State` struct behind `OSAllocatedUnfairLock`. Both the actor methods and sync methods share the same lock, so they are always consistent.
- **Single dictionary lookup** in get — one `storage[cid]` lookup, not two.
- **Inline renormalization** — LFU score normalization runs synchronously inside the lock, not in a spawned Task.
- **Cached content identifier hashing** — `ContentIdentifier` caches its hash value from the first 8 bytes of the hex string (SHA256 is perfectly distributed). Every Dictionary operation hashes a single `Int` instead of 64 bytes.
- **O(1) byte tracking** — `totalBytes` is a running counter, not a reduction.
- **Value-type state** — the `State` struct enables the compiler to optimize mutations in-place inside the lock closure.

## Performance

Benchmarked on Apple Silicon (M-series), release mode:

| Operation | Sync API | Actor API | Notes |
|-----------|----------|-----------|-------|
| get hit (17B) | **28ns** | 7.5us | Dictionary lookup + lock |
| get hit (4KB) | **28ns** | — | Data size has zero impact |
| get hit (256KB) | **28ns** | — | Dictionary stores references |
| get miss | **6ns** | 7.4us | Lock + dictionary miss |
| has (hit) | **11ns** | 7.3us | Lock + key existence check |
| has (miss) | **3ns** | — | Lock + empty dictionary |
| store (17B) | **142ns** | 7.6us | Dictionary insert + size tracking |
| delete | **78ns** | 7.2us | Dictionary remove |
| eviction store | **733ns** | 7.6us | Store + LFU sampling + eviction |
| mixed (80r/20w) | **265ns** | — | Realistic workload |
| CID create | 349ns | — | SHA256 (hardware) + hex encoding |

The sync API is **54-1233x faster** than the actor API. The actor overhead (~7us) dominates all operations — the actual storage work is sub-microsecond.

### Running benchmarks

```bash
swift run -c release MemoryCASBenchmarks --save-baseline
swift run -c release MemoryCASBenchmarks --check-baseline
```

## Testing

```bash
swift test
```

11 tests covering: round-trip storage, missing key lookups, overwrites, existence checks, LFU eviction, unbounded mode, explicit deletion, metrics tracking, size-based eviction, and totalBytes tracking.
