import Foundation

/// The photos of receipts as one ordinary ZIP file (stored, not compressed: they are JPEG already), made and read by the
/// app itself. It opens on any computer, and the app restores its own archives from it.
enum ReceiptArchive {
    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1) }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
        return value ^ 0xFFFFFFFF
    }

    private static func short(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }

    private static func long(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    private static func join(_ parts: [Data]) -> Data { Data(parts.joined()) }

    /// A ZIP of the given files (names must be plain ASCII file names).
    static func make(_ entries: [(name: String, data: Data)]) -> Data {
        var body = Data()
        var directory = Data()
        let dosDate = 0x21   // 1 January 1980: the files carry no dates
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(body.count)
            body.append(join([long(0x04034B50), short(20), short(0x0800), short(0), short(0), short(dosDate), long(crc), long(size), long(size),
                              short(name.count), short(0), name, entry.data]))
            directory.append(join([long(0x02014B50), short(20), short(20), short(0x0800), short(0), short(0), short(dosDate), long(crc), long(size), long(size),
                                   short(name.count), short(0), short(0), short(0), short(0), long(0), long(offset), name]))
        }
        let directoryOffset = UInt32(body.count)
        body.append(directory)
        body.append(join([long(0x06054B50), short(0), short(0), short(entries.count), short(entries.count), long(UInt32(directory.count)),
                          long(directoryOffset), short(0)]))
        return body
    }

    /// The files of an archive made by `make`; nil for anything else (another program's archive, a damaged file).
    static func read(_ zip: Data) -> [(name: String, data: Data)]? {
        let bytes = [UInt8](zip)
        func short(_ at: Int) -> Int { Int(bytes[at]) | (Int(bytes[at + 1]) << 8) }
        func long(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
        }
        var entries: [(name: String, data: Data)] = []
        var position = 0
        while position + 30 <= bytes.count, long(position) == 0x04034B50 {
            let flags = short(position + 6)
            let method = short(position + 8)
            let crc = long(position + 14)
            let compressed = Int(long(position + 18))
            let original = Int(long(position + 22))
            let nameLength = short(position + 26)
            let extraLength = short(position + 28)
            guard method == 0, flags & 0x08 == 0, compressed == original else { return nil }
            let nameStart = position + 30
            let dataStart = nameStart + nameLength + extraLength
            let end = dataStart + compressed
            guard end <= bytes.count, let name = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8) else { return nil }
            let data = Data(bytes[dataStart..<end])
            guard crc32(data) == crc else { return nil }
            entries.append((name, data))
            position = end
        }
        // The central directory follows, one record per file, and then the closing record that counts them: an archive
        // cut short (a download or a copy that stopped half way) has no such end and is refused as a whole.
        var cursor = position
        var listed = 0
        while cursor + 46 <= bytes.count, long(cursor) == 0x02014B50 {
            cursor += 46 + short(cursor + 28) + short(cursor + 30) + short(cursor + 32)
            listed += 1
        }
        guard listed == entries.count, cursor + 22 <= bytes.count, long(cursor) == 0x06054B50, short(cursor + 10) == entries.count else { return nil }
        return entries
    }
}
