import Foundation

/// Apache Thrift compact protocol, the subset the glasses' svc15 speaks.
/// Types follow the compact spec: 1/2 are the two booleans, 12 is a struct.
enum TC {
    static let stop: UInt8 = 0
    static let tTrue: UInt8 = 1
    static let tFalse: UInt8 = 2
    static let i8: UInt8 = 3
    static let i16: UInt8 = 4
    static let i32: UInt8 = 5
    static let i64: UInt8 = 6
    static let double: UInt8 = 7
    static let bin: UInt8 = 8
    static let list: UInt8 = 9
    static let set: UInt8 = 10
    static let map: UInt8 = 11
    static let structure: UInt8 = 12
    /// fbthrift's compact extension: a 4-byte big-endian IEEE float.
    static let float: UInt8 = 13
}

enum ThriftError: Error, CustomStringConvertible {
    case truncated(String)
    case badType(UInt8)
    case limit(String)

    var description: String {
        switch self {
        case .truncated(let what): return "truncated \(what)"
        case .badType(let t): return "bad compact type \(t)"
        case .limit(let what): return "compact \(what) exceeds its limit"
        }
    }
}

/// Writes one struct: fields are written in ascending order, the writer tracks the last field id.
final class ThriftWriter {
    private var buf = Data()
    private var last: Int = 0

    private func header(_ fid: Int, _ type: UInt8) {
        let delta = fid - last
        if delta >= 1, delta <= 15 {
            buf.append(UInt8((delta << 4)) | type)
        } else {
            buf.append(type)
            let signed = Int64(fid)
            buf.append(Varint.encode(UInt64(bitPattern: (signed << 1) ^ (signed >> 15))))
        }
        last = fid
    }

    @discardableResult
    func bool(_ fid: Int, _ v: Bool) -> ThriftWriter {
        header(fid, v ? TC.tTrue : TC.tFalse)
        return self
    }

    @discardableResult
    func i32(_ fid: Int, _ v: Int32) -> ThriftWriter {
        header(fid, TC.i32)
        buf.append(ThriftWriter.zigzag(UInt64(bitPattern: Int64(v)), bits: 32))
        return self
    }

    @discardableResult
    func i64(_ fid: Int, _ v: Int64) -> ThriftWriter {
        header(fid, TC.i64)
        buf.append(ThriftWriter.zigzag(UInt64(bitPattern: v), bits: 64))
        return self
    }

    @discardableResult
    func string(_ fid: Int, _ v: String) -> ThriftWriter { binary(fid, Data(v.utf8)) }

    @discardableResult
    func binary(_ fid: Int, _ v: Data) -> ThriftWriter {
        header(fid, TC.bin)
        buf.append(Varint.encode(UInt64(v.count)))
        buf.append(v)
        return self
    }

    /// A nested struct already produced by another writer.
    @discardableResult
    func structField(_ fid: Int, _ body: Data) -> ThriftWriter {
        header(fid, TC.structure)
        buf.append(body)
        return self
    }

    @discardableResult
    func listOfBinaries(_ fid: Int, _ items: [Data]) -> ThriftWriter {
        header(fid, TC.list)
        if items.count < 15 {
            buf.append(UInt8((items.count << 4)) | TC.bin)
        } else {
            buf.append(0xF0 | TC.bin)
            buf.append(Varint.encode(UInt64(items.count)))
        }
        for item in items {
            buf.append(Varint.encode(UInt64(item.count)))
            buf.append(item)
        }
        return self
    }

    func done() -> Data {
        var out = buf
        out.append(TC.stop)
        return out
    }

    /// Compact protocol zigzags signed values; a field id goes through the 16-bit form.
    static func zigzag(_ value: UInt64, bits: Int) -> Data {
        let signed = Int64(bitPattern: value)
        let shifted = (signed << 1) ^ (signed >> (bits - 1))
        return Varint.encode(UInt64(bitPattern: shifted))
    }
}

enum Varint {
    static func encode(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while true {
            if v & ~0x7F == 0 {
                out.append(UInt8(v))
                return out
            }
            out.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
    }

    static func decode(_ data: Data, _ offset: Int) throws -> (UInt64, Int) {
        guard offset >= data.startIndex else { throw ThriftError.truncated("varint") }
        var shift: UInt64 = 0
        var value: UInt64 = 0
        var i = offset
        while i < data.endIndex {
            let b = data[i]
            guard shift < 63 || b <= 1 else { throw ThriftError.limit("varint") }
            value |= UInt64(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 { return (value, i) }
            shift += 7
            if shift > 63 { break }
        }
        throw ThriftError.truncated("varint")
    }
}

/// Reads a compact struct into `[fieldId: value]`, where values are Int64, Double, Data, Bool, [Any],
/// nested `[Int: Any]` structs or `[String: Any]` maps.
enum ThriftCompact {
    private static let maximumDepth = 64

    static func loads(_ data: Data) throws -> [Int: Any] {
        try readStruct(data, data.startIndex, depth: 0).fields
    }

    private static func readStruct(_ data: Data, _ offset: Int, depth: Int) throws -> (fields: [Int: Any], next: Int) {
        guard depth < maximumDepth else { throw ThriftError.limit("nesting") }
        var fields: [Int: Any] = [:]
        var fid = 0
        var i = offset
        while i < data.endIndex {
            let head = data[i]
            i += 1
            if head == TC.stop { return (fields, i) }
            let type = head & 0x0F
            let delta = Int(head >> 4)
            if delta == 0 {
                let (raw, next) = try Varint.decode(data, i)
                let field = Int64(raw >> 1) ^ -Int64(raw & 1)
                guard let id = Int16(exactly: field) else { throw ThriftError.limit("field ID") }
                fid = Int(id)
                i = next
            } else {
                fid += delta
                guard fid <= Int(Int16.max) else { throw ThriftError.limit("field ID") }
            }
            let read = try readValue(data, i, type, depth: depth)
            fields[fid] = read.value
            i = read.next
        }
        return (fields, i)
    }

    private static func readValue(_ data: Data, _ start: Int, _ type: UInt8, depth: Int) throws -> (value: Any, next: Int) {
        guard depth < maximumDepth else { throw ThriftError.limit("nesting") }
        var i = start
        let end = data.endIndex
        switch type {
        case TC.tTrue, TC.tFalse:
            return (type == TC.tTrue, i)
        case TC.i8:
            guard i < end else { throw ThriftError.truncated("i8") }
            return (Int64(Int8(bitPattern: data[i])), i + 1)
        case TC.i16, TC.i32, TC.i64:
            let (raw, next) = try Varint.decode(data, i)
            let signed = Int64(bitPattern: raw)
            let decoded = (signed >> 1) ^ -(signed & 1)
            return (decoded, next)
        case TC.double:
            // Visor's reader (core/protocol Thrift.kt) takes doubles little-endian.
            guard end - i >= 8 else { throw ThriftError.truncated("double") }
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(data[i + k]) << (8 * UInt64(k)) }
            return (Double(bitPattern: bits), i + 8)
        case TC.float:
            guard end - i >= 4 else { throw ThriftError.truncated("float") }
            var bits: UInt32 = 0
            for k in 0..<4 { bits = (bits << 8) | UInt32(data[i + k]) }
            return (Double(Float(bitPattern: bits)), i + 4)
        case TC.map:
            // ev57 keeps its slots as map<string, list<struct>>; without this case the whole
            // event failed to parse and the glasses' transcript was lost.
            let (size, afterSize) = try Varint.decode(data, i)
            i = afterSize
            guard size > 0 else { return ([String: Any](), i) }
            guard i < end else { throw ThriftError.truncated("map") }
            let kinds = data[i]
            i += 1
            // Every entry takes at least two bytes, so a larger count cannot be real.
            guard size <= UInt64(end - i) / 2 else { throw ThriftError.truncated("map") }
            var entries: [String: Any] = [:]
            for _ in 0..<Int(size) {
                let key = try readElement(data, i, kinds >> 4, depth: depth + 1)
                let value = try readElement(data, key.next, kinds & 0x0F, depth: depth + 1)
                entries[mapKey(key.value)] = value.value
                i = value.next
            }
            return (entries, i)
        case TC.bin:
            let (len, next) = try Varint.decode(data, i)
            i = next
            guard len <= UInt64(end - i) else { throw ThriftError.truncated("binary") }
            let n = Int(len)
            return (data.subdata(in: i..<(i + n)), i + n)
        case TC.list, TC.set:
            guard i < end else { throw ThriftError.truncated("list") }
            let head = data[i]
            i += 1
            var count = Int(head >> 4)
            let etype = head & 0x0F
            if count == 15 {
                let (len, next) = try Varint.decode(data, i)
                i = next
                guard len <= UInt64(end - i) else { throw ThriftError.truncated("list") }
                count = Int(len)
            }
            guard count <= end - i else { throw ThriftError.truncated("list") }
            if etype == TC.tTrue || etype == TC.tFalse {
                let values = data[i..<(i + count)]
                guard values.allSatisfy({ $0 == TC.tTrue || $0 == TC.tFalse }) else {
                    throw ThriftError.badType(etype)
                }
                return (values.map { $0 == TC.tTrue }, i + count)
            }
            var items: [Any] = []
            for _ in 0..<count {
                let read = try readValue(data, i, etype, depth: depth + 1)
                guard read.next > i else { throw ThriftError.truncated("list element") }
                items.append(read.value)
                i = read.next
            }
            return (items, i)
        case TC.structure:
            let inner = try readStruct(data, i, depth: depth + 1)
            return (inner.fields, inner.next)
        default:
            throw ThriftError.badType(type)
        }
    }

    /// Inside a list, set or map a bool is a byte of its own (1 true, 2 false).
    private static func readElement(_ data: Data, _ start: Int, _ type: UInt8, depth: Int) throws -> (value: Any, next: Int) {
        guard type == TC.tTrue || type == TC.tFalse else { return try readValue(data, start, type, depth: depth) }
        guard start < data.endIndex else { throw ThriftError.truncated("bool element") }
        return (data[start] == TC.tTrue, start + 1)
    }

    /// Map keys become strings; binary keys that are not UTF-8 become hex.
    private static func mapKey(_ value: Any) -> String {
        switch value {
        case let d as Data: return String(data: d, encoding: .utf8) ?? d.hex
        case let n as Int64: return String(n)
        case let b as Bool: return b ? "true" : "false"
        default: return String(describing: value)
        }
    }
}

// Small accessors so call sites stay readable.
extension Dictionary where Key == Int, Value == Any {
    func int(_ fid: Int) -> Int? {
        switch self[fid] {
        case let v as Int64: return Int(v)
        case let v as Int: return v
        default: return nil
        }
    }

    func bytes(_ fid: Int) -> Data? {
        switch self[fid] {
        case let v as Data: return v
        case let v as String: return Data(v.utf8)
        default: return nil
        }
    }

    func text(_ fid: Int) -> String {
        guard let d = bytes(fid) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    func bool(_ fid: Int) -> Bool {
        (self[fid] as? Bool) ?? false
    }

    func structField(_ fid: Int) -> [Int: Any] {
        (self[fid] as? [Int: Any]) ?? [:]
    }

    func list(_ fid: Int) -> [Any] {
        (self[fid] as? [Any]) ?? []
    }

    func mapField(_ fid: Int) -> [String: Any] {
        (self[fid] as? [String: Any]) ?? [:]
    }
}
