import Foundation

func daysPartUrl(_ dir: URL, _ index: Int) -> URL {
    dir.appending(component: String(format: "part-%06d.bin", index))
}

func daysTailUrl(_ dir: URL, _ index: Int) -> URL {
    dir.appending(component: String(format: "tail-%06d.bin", index))
}

func daysAssembleRemainder(dir: URL, partSize: Int, committed: Int, start: Int64, end: Int64, out: URL) throws {
    let size = Int64(partSize)
    let firstPart = Int(start / size)
    let skip = Int(start % size)
    let lastPart = Int((end - 1) / size)
    let manager = FileManager.default
    if !manager.fileExists(atPath: out.path) {
        manager.createFile(atPath: out.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }
    for index in firstPart ... lastPart {
        let isTail = index >= committed
        let source = isTail ? daysTailUrl(dir, committed) : daysPartUrl(dir, index)
        guard manager.fileExists(atPath: source.path) else {
            continue
        }
        let whole = try Data(contentsOf: source, options: .alwaysMapped)
        let from = index == firstPart ? skip : 0
        let to = min(Int(end - Int64(index) * size), whole.count)
        guard from <= to else {
            continue
        }
        let position = index == firstPart ? Int64(0) : Int64(index - firstPart) * size - Int64(skip)
        try handle.seek(toOffset: UInt64(position))
        try handle.write(contentsOf: whole.subdata(in: from ..< to))
        try handle.synchronize()
        if !isTail {
            try? manager.removeItem(at: source)
        }
    }
    try handle.truncate(atOffset: UInt64(end - start))
    try handle.synchronize()
}

func daysTrimFile(_ file: URL, dropFirst: Int64) throws {
    let manager = FileManager.default
    let copy = file.deletingLastPathComponent().appending(component: "trim.tmp")
    try? manager.removeItem(at: copy)
    manager.createFile(atPath: copy.path, contents: nil)
    let input = try FileHandle(forReadingFrom: file)
    let output = try FileHandle(forWritingTo: copy)
    try input.seek(toOffset: UInt64(dropFirst))
    while let block = try input.read(upToCount: 8 * 1024 * 1024), !block.isEmpty {
        try output.write(contentsOf: block)
    }
    try output.synchronize()
    try output.close()
    try input.close()
    try manager.removeItem(at: file)
    try manager.moveItem(at: copy, to: file)
}

func daysReadRange(_ file: URL, offset: Int64, count: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    return try handle.read(upToCount: count) ?? Data()
}

func daysCloneFile(_ source: URL, out: URL) throws {
    let manager = FileManager.default
    try? manager.removeItem(at: out)
    try manager.copyItem(at: source, to: out)
    try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: out.path)
}

func daysCopyRange(_ source: URL, start: Int64, end: Int64, out: URL) throws {
    let manager = FileManager.default
    try? manager.removeItem(at: out)
    manager.createFile(atPath: out.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: out)
    defer {
        try? input.close()
        try? output.close()
    }
    try input.seek(toOffset: UInt64(start))
    var left = end - start
    while left > 0, let block = try input.read(upToCount: Int(min(left, 8 * 1024 * 1024))), !block.isEmpty {
        try output.write(contentsOf: block)
        left -= Int64(block.count)
    }
    try output.synchronize()
}
