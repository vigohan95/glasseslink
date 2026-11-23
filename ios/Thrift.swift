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
}

enum ThriftError: Error, CustomStringConvertible {
    case truncated(String)
    case badType(UInt8)

    var description: String {
        switch self {
        case .truncated(let what): return "truncated \(what)"
        case .badType(let t): return "bad compact type \(t)"
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
    func struct(_ fid: Int, _ body: Data) -> ThriftWriter {
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
        var shift: UInt64 = 0
        var value: UInt64 = 0
        var i = offset
        while i < data.count {
            let b = data[i]
            value |= UInt64(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 { return (value, i) }
            shift += 7
            if shift > 63 { break }
        }
        throw ThriftError.truncated("varint")
    }
}

/// Reads a compact struct into `[fieldId: value]`, where values are Int64, Data, Bool or [Any].
enum ThriftCompact {
    static func loads(_ data: Data) throws -> [Int: Any] {
        try readStruct(data, 0).fields
    }

    static func readStruct(_ data: Data, _ offset: Int) throws -> (fields: [Int: Any], next: Int) {
        var fields: [Int: Any] = [:]
        var fid = 0
        var i = offset
        while i < data.count {
            let head = data[i]
            i += 1
            if head == TC.stop { return (fields, i) }
            let type = head & 0x0F
            let delta = Int(head >> 4)
            if delta == 0 {
                let (raw, next) = try Varint.decode(data, i)
                let signed = Int64(bitPattern: raw)
                fid = Int((signed >> 1) ^ -(signed & 1))
                i = next
            } else {
                fid += delta
            }
            let read = try readValue(data, i, type)
            fields[fid] = read.value
            i = read.next
        }
        return (fields, i)
    }

    private static func readValue(_ data: Data, _ start: Int, _ type: UInt8) throws -> (value: Any, next: Int) {
        var i = start
        switch type {
        case TC.tTrue, TC.tFalse:
            return (type == TC.tTrue, i)
        case TC.i8:
            guard i < data.count else { throw ThriftError.truncated("i8") }
            return (Int64(Int8(bitPattern: data[i])), i + 1)
        case TC.i16, TC.i32, TC.i64:
            let (raw, next) = try Varint.decode(data, i)
            let signed = Int64(bitPattern: raw)
            let decoded = (signed >> 1) ^ -(signed & 1)
            return (decoded, next)
        case TC.double:
            guard i + 8 <= data.count else { throw ThriftError.truncated("double") }
            var bits: UInt64 = 0
            for k in 0..<8 { bits = (bits << 8) | UInt64(data[i + k]) }
            i += 8
            return (Double(bitPattern: bits), i)
        case TC.bin:
            let (len, next) = try Varint.decode(data, i)
            i = next
            let n = Int(len)
            guard i + n <= data.count else { throw ThriftError.truncated("binary") }
            return (data.subdata(in: i..<(i + n)), i + n)
        case TC.list, TC.set:
            guard i < data.count else { throw ThriftError.truncated("list") }
            let head = data[i]
            i += 1
            var count = Int(head >> 4)
            let etype = head & 0x0F
            if count == 15 {
                let (len, next) = try Varint.decode(data, i)
                count = Int(len)
                i = next
            }
            var items: [Any] = []
            for _ in 0..<count {
                let read = try readValue(data, i, etype)
                items.append(read.value)
                i = read.next
            }
            return (items, i)
        case TC.structure:
            let inner = try readStruct(data, i)
            return (inner.fields, inner.next)
        default:
            throw ThriftError.badType(type)
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

    func struct(_ fid: Int) -> [Int: Any] {
        (self[fid] as? [Int: Any]) ?? [:]
    }

    func list(_ fid: Int) -> [Any] {
        (self[fid] as? [Any]) ?? []
    }
}
