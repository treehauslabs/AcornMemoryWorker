import Foundation
import Acorn
import AcornMemoryWorker

@main
struct MemoryCASBenchmarks {
    static let baselineURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".memory-benchmark-baseline.json")

    static func main() async throws {
        let args = CommandLine.arguments
        let shouldSave = args.contains("--save-baseline")
        let shouldCheck = args.contains("--check-baseline")

        let warmupIterations = 100
        let samples = 50
        let opsPerSample = 1000

        let smallData = Data("hello, memory CAS".utf8)
        let mediumData = Data(repeating: 0xAB, count: 4096)
        let largeData = Data(repeating: 0xCD, count: 256 * 1024)

        let smallCID = ContentIdentifier(for: smallData)
        let mediumCID = ContentIdentifier(for: mediumData)
        let largeCID = ContentIdentifier(for: largeData)
        let missingCID = ContentIdentifier(for: Data("not-stored".utf8))

        var results: [BenchmarkResult] = []
        let clock = ContinuousClock()

        print("=== Actor API (async/await) ===")

        // --- store (small) ---
        do {
            let worker = MemoryCASWorker()
            for _ in 0..<warmupIterations { await worker.storeLocal(cid: smallCID, data: smallData) }
            var timings: [Double] = []
            for _ in 0..<samples {
                let w = MemoryCASWorker()
                var cids: [ContentIdentifier] = []
                for i in 0..<opsPerSample {
                    cids.append(ContentIdentifier(for: Data("store-\(i)".utf8)))
                }
                let start = clock.now
                for i in 0..<opsPerSample {
                    await w.storeLocal(cid: cids[i], data: smallData)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "store (17B)", iterations: opsPerSample, samples: timings))
        }

        // --- get hit (small) ---
        do {
            let worker = MemoryCASWorker()
            await worker.storeLocal(cid: smallCID, data: smallData)
            for _ in 0..<warmupIterations { _ = await worker.getLocal(cid: smallCID) }
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = await worker.getLocal(cid: smallCID)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "get hit (17B)", iterations: opsPerSample, samples: timings))
        }

        // --- get miss ---
        do {
            let worker = MemoryCASWorker()
            for _ in 0..<warmupIterations { _ = await worker.getLocal(cid: missingCID) }
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = await worker.getLocal(cid: missingCID)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "get miss", iterations: opsPerSample, samples: timings))
        }

        // --- has (hit) ---
        do {
            let worker = MemoryCASWorker()
            await worker.storeLocal(cid: smallCID, data: smallData)
            for _ in 0..<warmupIterations { _ = await worker.has(cid: smallCID) }
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = await worker.has(cid: smallCID)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "has (hit)", iterations: opsPerSample, samples: timings))
        }

        // --- delete ---
        do {
            var timings: [Double] = []
            for _ in 0..<samples {
                let w = MemoryCASWorker()
                var cids: [ContentIdentifier] = []
                for i in 0..<opsPerSample {
                    let d = Data("del-\(i)".utf8)
                    let c = ContentIdentifier(for: d)
                    cids.append(c)
                    await w.storeLocal(cid: c, data: d)
                }
                let start = clock.now
                for i in 0..<opsPerSample {
                    await w.delete(cid: cids[i])
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "delete", iterations: opsPerSample, samples: timings))
        }

        // --- eviction store ---
        do {
            var timings: [Double] = []
            for _ in 0..<samples {
                let w = MemoryCASWorker(capacity: 100, sampleSize: 5)
                var cids: [ContentIdentifier] = []
                for i in 0..<opsPerSample {
                    cids.append(ContentIdentifier(for: Data("evict-\(i)".utf8)))
                }
                let start = clock.now
                for i in 0..<opsPerSample {
                    await w.storeLocal(cid: cids[i], data: smallData)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "eviction store", iterations: opsPerSample, samples: timings))
        }

        print("")
        print("=== Sync API (lock-based, bypasses actor hop) ===")

        // --- sync store (small) ---
        do {
            var timings: [Double] = []
            for _ in 0..<samples {
                let w = MemoryCASWorker()
                var cids: [ContentIdentifier] = []
                for i in 0..<opsPerSample {
                    cids.append(ContentIdentifier(for: Data("sstore-\(i)".utf8)))
                }
                let start = clock.now
                for i in 0..<opsPerSample {
                    w.syncStore(cid: cids[i], data: smallData)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "sync store (17B)", iterations: opsPerSample, samples: timings))
        }

        // --- sync get hit (small) ---
        do {
            let worker = MemoryCASWorker()
            worker.syncStore(cid: smallCID, data: smallData)
            for _ in 0..<warmupIterations { _ = worker.syncGet(cid: smallCID) }
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = worker.syncGet(cid: smallCID)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "sync get hit (17B)", iterations: opsPerSample, samples: timings))
        }

        // --- sync get hit (4KB) ---
        do {
            let worker = MemoryCASWorker()
            worker.syncStore(cid: mediumCID, data: mediumData)
            for _ in 0..<warmupIterations { _ = worker.syncGet(cid: mediumCID) }
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = worker.syncGet(cid: mediumCID)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "sync get hit (4KB)", iterations: opsPerSample, samples: timings))
        }

        // --- sync get hit (256KB) ---
        do {
            let worker = MemoryCASWorker()
            worker.syncStore(cid: largeCID, data: largeData)
            for _ in 0..<warmupIterations { _ = worker.syncGet(cid: largeCID) }
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = worker.syncGet(cid: largeCID)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "sync get hit (256KB)", iterations: opsPerSample, samples: timings))
        }

        // --- sync get miss ---
        do {
            let worker = MemoryCASWorker()
            for _ in 0..<warmupIterations { _ = worker.syncGet(cid: missingCID) }
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = worker.syncGet(cid: missingCID)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "sync get miss", iterations: opsPerSample, samples: timings))
        }

        // --- sync has (hit) ---
        do {
            let worker = MemoryCASWorker()
            worker.syncStore(cid: smallCID, data: smallData)
            for _ in 0..<warmupIterations { _ = worker.syncHas(cid: smallCID) }
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = worker.syncHas(cid: smallCID)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "sync has (hit)", iterations: opsPerSample, samples: timings))
        }

        // --- sync has (miss) ---
        do {
            let worker = MemoryCASWorker()
            for _ in 0..<warmupIterations { _ = worker.syncHas(cid: missingCID) }
            var timings: [Double] = []
            for _ in 0..<samples {
                let start = clock.now
                for _ in 0..<opsPerSample {
                    _ = worker.syncHas(cid: missingCID)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "sync has (miss)", iterations: opsPerSample, samples: timings))
        }

        // --- sync delete ---
        do {
            var timings: [Double] = []
            for _ in 0..<samples {
                let w = MemoryCASWorker()
                var cids: [ContentIdentifier] = []
                for i in 0..<opsPerSample {
                    let d = Data("sdel-\(i)".utf8)
                    let c = ContentIdentifier(for: d)
                    cids.append(c)
                    w.syncStore(cid: c, data: d)
                }
                let start = clock.now
                for i in 0..<opsPerSample {
                    w.syncDelete(cid: cids[i])
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "sync delete", iterations: opsPerSample, samples: timings))
        }

        // --- sync eviction store ---
        do {
            var timings: [Double] = []
            for _ in 0..<samples {
                let w = MemoryCASWorker(capacity: 100, sampleSize: 5)
                var cids: [ContentIdentifier] = []
                for i in 0..<opsPerSample {
                    cids.append(ContentIdentifier(for: Data("sevict-\(i)".utf8)))
                }
                let start = clock.now
                for i in 0..<opsPerSample {
                    w.syncStore(cid: cids[i], data: smallData)
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "sync evict store", iterations: opsPerSample, samples: timings))
        }

        // --- sync mixed (80r/20w) ---
        do {
            var timings: [Double] = []
            for _ in 0..<samples {
                let w = MemoryCASWorker(capacity: 500)
                var cids: [ContentIdentifier] = []
                for i in 0..<200 {
                    let d = Data("smix-\(i)".utf8)
                    let c = ContentIdentifier(for: d)
                    cids.append(c)
                    w.syncStore(cid: c, data: d)
                }
                let start = clock.now
                for i in 0..<opsPerSample {
                    if i % 5 == 0 {
                        let d = Data("snew-\(i)".utf8)
                        let c = ContentIdentifier(for: d)
                        w.syncStore(cid: c, data: d)
                    } else {
                        let c = cids[i % cids.count]
                        _ = w.syncGet(cid: c)
                    }
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "sync mixed 80r/20w", iterations: opsPerSample, samples: timings))
        }

        // --- CID create ---
        do {
            var timings: [Double] = []
            var dataItems: [Data] = []
            for i in 0..<opsPerSample {
                dataItems.append(Data("cid-bench-\(i)".utf8))
            }
            for _ in 0..<samples {
                let start = clock.now
                for i in 0..<opsPerSample {
                    _ = ContentIdentifier(for: dataItems[i])
                }
                let elapsed = start.duration(to: clock.now)
                let us = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
                timings.append(us / Double(opsPerSample))
            }
            results.append(BenchmarkResult(name: "CID create", iterations: opsPerSample, samples: timings))
        }

        printReport(results)

        if shouldSave {
            try saveBaseline(results, to: baselineURL)
        }
        if shouldCheck {
            try compareBaseline(results, from: baselineURL)
        }
    }
}
