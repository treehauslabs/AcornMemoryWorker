import Testing
import Foundation
import Acorn
@testable import AcornMemoryWorker

@Suite("MemoryCASWorker")
struct MemoryCASWorkerTests {

    @Test("Put and get round-trip")
    func testPutGet() async {
        let worker = MemoryCASWorker()
        let data = Data("hello".utf8)
        let cid = ContentIdentifier(for: data)

        await worker.storeLocal(cid: cid, data: data)
        let result = await worker.get(cid: cid)
        #expect(result == data)
    }

    @Test("Get missing CID returns nil")
    func testGetMissing() async {
        let worker = MemoryCASWorker()
        let cid = ContentIdentifier(for: Data("missing".utf8))
        #expect(await worker.get(cid: cid) == nil)
    }

    @Test("Put overwrites silently")
    func testPutOverwrite() async {
        let worker = MemoryCASWorker()
        let data1 = Data("v1".utf8)
        let data2 = Data("v2".utf8)
        let cid = ContentIdentifier(for: data1)

        await worker.storeLocal(cid: cid, data: data1)
        await worker.storeLocal(cid: cid, data: data2)
        #expect(await worker.get(cid: cid) == data2)
    }

    @Test("has returns true for stored CID")
    func testHasTrue() async {
        let worker = MemoryCASWorker()
        let data = Data("exists".utf8)
        let cid = ContentIdentifier(for: data)

        await worker.storeLocal(cid: cid, data: data)
        #expect(await worker.has(cid: cid) == true)
    }

    @Test("has returns false for missing CID")
    func testHasFalse() async {
        let worker = MemoryCASWorker()
        let cid = ContentIdentifier(for: Data("ghost".utf8))
        #expect(await worker.has(cid: cid) == false)
    }

    @Test("Evicts at capacity")
    func testEviction() async {
        let worker = MemoryCASWorker(capacity: 2, sampleSize: 10)
        let a = ContentIdentifier(for: Data("a".utf8))
        let b = ContentIdentifier(for: Data("b".utf8))
        let c = ContentIdentifier(for: Data("c".utf8))

        await worker.storeLocal(cid: a, data: Data("a".utf8))
        await worker.storeLocal(cid: b, data: Data("b".utf8))

        for _ in 0..<10 {
            _ = await worker.getLocal(cid: a)
        }

        await worker.storeLocal(cid: c, data: Data("c".utf8))

        #expect(await worker.has(cid: a) == true)
        #expect(await worker.has(cid: c) == true)
        #expect(await worker.has(cid: b) == false)
    }

    @Test("Without capacity never evicts")
    func testNoEviction() async {
        let worker = MemoryCASWorker()
        for i in 0..<100 {
            let data = Data("item-\(i)".utf8)
            let cid = ContentIdentifier(for: data)
            await worker.storeLocal(cid: cid, data: data)
        }
        let data = Data("item-0".utf8)
        let cid = ContentIdentifier(for: data)
        #expect(await worker.has(cid: cid) == true)
    }

    @Test("Delete removes entry")
    func testDelete() async {
        let worker = MemoryCASWorker()
        let data = Data("deleteme".utf8)
        let cid = ContentIdentifier(for: data)

        await worker.storeLocal(cid: cid, data: data)
        #expect(await worker.has(cid: cid) == true)

        await worker.delete(cid: cid)
        #expect(await worker.has(cid: cid) == false)
        #expect(await worker.getLocal(cid: cid) == nil)
    }

    @Test("Metrics track operations correctly")
    func testMetrics() async {
        let worker = MemoryCASWorker(capacity: 2, sampleSize: 10)
        let data = Data("metric".utf8)
        let cid = ContentIdentifier(for: data)
        let missing = ContentIdentifier(for: Data("nope".utf8))

        await worker.storeLocal(cid: cid, data: data)
        _ = await worker.getLocal(cid: cid)
        _ = await worker.getLocal(cid: missing)
        await worker.delete(cid: cid)

        let m = await worker.metrics
        #expect(m.stores == 1)
        #expect(m.hits == 1)
        #expect(m.misses == 1)
        #expect(m.deletions == 1)
    }

    @Test("Size-based eviction respects maxBytes")
    func testMaxBytesEviction() async {
        let worker = MemoryCASWorker(maxBytes: 2, sampleSize: 10)
        let a = ContentIdentifier(for: Data("a".utf8))
        let b = ContentIdentifier(for: Data("b".utf8))
        let c = ContentIdentifier(for: Data("c".utf8))

        await worker.storeLocal(cid: a, data: Data("a".utf8))
        await worker.storeLocal(cid: b, data: Data("b".utf8))

        for _ in 0..<10 {
            _ = await worker.getLocal(cid: a)
        }

        await worker.storeLocal(cid: c, data: Data("c".utf8))

        #expect(await worker.getLocal(cid: a) != nil)
        #expect(await worker.getLocal(cid: c) != nil)
        #expect(await worker.getLocal(cid: b) == nil)
    }

    @Test("totalBytes tracks correctly across operations")
    func testTotalBytes() async {
        let worker = MemoryCASWorker()
        let dataA = Data("aaaa".utf8)
        let dataB = Data("bb".utf8)
        let cidA = ContentIdentifier(for: dataA)
        let cidB = ContentIdentifier(for: dataB)

        #expect(await worker.totalBytes == 0)

        await worker.storeLocal(cid: cidA, data: dataA)
        #expect(await worker.totalBytes == 4)

        await worker.storeLocal(cid: cidB, data: dataB)
        #expect(await worker.totalBytes == 6)

        await worker.delete(cid: cidA)
        #expect(await worker.totalBytes == 2)
    }
}
