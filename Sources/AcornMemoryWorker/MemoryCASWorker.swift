import Foundation
#if canImport(os)
import os
#endif
import Acorn

public actor MemoryCASWorker: AcornCASWorker {
    public let timeout: Duration?
    public var near: (any AcornCASWorker)?
    public var far: (any AcornCASWorker)?

    internal let _state: LockedMemoryState

    public init(
        capacity: Int? = nil,
        maxBytes: Int? = nil,
        halfLife: Duration = .seconds(300),
        sampleSize: Int = 5,
        timeout: Duration? = nil
    ) {
        self.timeout = timeout
        var cache: LFUDecayCache? = nil
        if let capacity {
            cache = LFUDecayCache(capacity: capacity, halfLife: halfLife, sampleSize: sampleSize)
        } else if maxBytes != nil {
            cache = LFUDecayCache(capacity: .max, halfLife: halfLife, sampleSize: sampleSize)
        }
        self._state = LockedMemoryState(initialState: State(cache: cache, maxBytes: maxBytes))
    }

    public func has(cid: ContentIdentifier) -> Bool {
        syncHas(cid: cid)
    }

    public func getLocal(cid: ContentIdentifier) async -> Data? {
        syncGet(cid: cid)
    }

    public func storeLocal(cid: ContentIdentifier, data: Data) async {
        syncStore(cid: cid, data: data)
    }

    public func delete(cid: ContentIdentifier) {
        syncDelete(cid: cid)
    }

    public var metrics: CASMetrics {
        _state.withLock { $0.metrics }
    }

    public var totalBytes: Int {
        _state.withLock { $0.totalBytes }
    }

    // MARK: - Lock-based synchronous API (bypasses actor hop)

    public nonisolated func syncHas(cid: ContentIdentifier) -> Bool {
        _state.withLock { $0.storage[cid] != nil }
    }

    public nonisolated func syncGet(cid: ContentIdentifier) -> Data? {
        _state.withLock { state in
            guard let data = state.storage[cid] else {
                state.metrics.misses += 1
                return nil
            }
            if state.cache != nil {
                state.cache!.recordAccess(cid)
                if let work = state.cache!.claimRenormalization() {
                    for key in work.keys {
                        state.cache!.applyRenormFactor(key, factor: work.factor)
                    }
                }
            }
            state.metrics.hits += 1
            return data
        }
    }

    public nonisolated func syncStore(cid: ContentIdentifier, data: Data) {
        _state.withLock { state in
            if state.cache != nil {
                while state.cache!.needsEviction(for: cid) || state.isOverByteLimit(adding: data.count, for: cid) {
                    guard let victim = state.cache!.evictionCandidate(), victim != cid else { break }
                    state.storage.removeValue(forKey: victim)
                    state.cache!.remove(victim)
                    let oldSize = state.itemSizes.removeValue(forKey: victim) ?? 0
                    state.totalBytes -= oldSize
                    state.metrics.evictions += 1
                }
                state.cache!.recordAccess(cid)
                if let work = state.cache!.claimRenormalization() {
                    for key in work.keys {
                        state.cache!.applyRenormFactor(key, factor: work.factor)
                    }
                }
            }
            let oldSize = state.itemSizes[cid] ?? 0
            state.itemSizes[cid] = data.count
            state.totalBytes += data.count - oldSize
            state.storage[cid] = data
            state.metrics.stores += 1
        }
    }

    public nonisolated func syncDelete(cid: ContentIdentifier) {
        _state.withLock { state in
            state.cache?.remove(cid)
            state.storage.removeValue(forKey: cid)
            let oldSize = state.itemSizes.removeValue(forKey: cid) ?? 0
            state.totalBytes -= oldSize
            state.metrics.deletions += 1
        }
    }
}

extension MemoryCASWorker {
    struct State: Sendable {
        var storage: [ContentIdentifier: Data] = [:]
        var cache: LFUDecayCache?
        let maxBytes: Int?
        var itemSizes: [ContentIdentifier: Int] = [:]
        var totalBytes: Int = 0
        var metrics = CASMetrics()

        func isOverByteLimit(adding newSize: Int, for cid: ContentIdentifier) -> Bool {
            guard let maxBytes else { return false }
            let currentTotal = totalBytes - (itemSizes[cid] ?? 0) + newSize
            return currentTotal > maxBytes
        }
    }
}

#if canImport(os)
struct LockedMemoryState: Sendable {
    private let _lock: OSAllocatedUnfairLock<MemoryCASWorker.State>

    init(initialState: MemoryCASWorker.State) {
        _lock = OSAllocatedUnfairLock(initialState: initialState)
    }

    @inline(__always)
    func withLock<T: Sendable>(_ body: @Sendable (inout MemoryCASWorker.State) throws -> T) rethrows -> T {
        try _lock.withLock(body)
    }
}
#else
final class LockedMemoryState: @unchecked Sendable {
    private var _state: MemoryCASWorker.State
    private let _lock = NSLock()

    init(initialState: MemoryCASWorker.State) {
        _state = initialState
    }

    @inline(__always)
    func withLock<T>(_ body: (inout MemoryCASWorker.State) throws -> T) rethrows -> T {
        _lock.lock()
        defer { _lock.unlock() }
        return try body(&_state)
    }
}
#endif
