import Foundation

/// Legacy Excel 97–2003 workbooks: a native reader for the BIFF8 `Workbook` stream inside an OLE2
/// compound file. Reads every worksheet's values (shared strings, numbers, RK numbers, booleans, errors,
/// cached formula results) and turns date-formatted numbers into dates. Excel 95 (BIFF5) and
/// password-protected files are reported as unsupported.
enum SpreadsheetXLS {
    static func read(_ url: URL) throws -> SpreadsheetWorkbook {
        guard let data = try? Data(contentsOf: url) else { throw KlickError.unreadable(url.lastPathComponent) }
        let file = [UInt8](data)
        guard let compound = CompoundFile(file) else { throw KlickError.unreadable(url.lastPathComponent) }
        guard let stream = compound.stream(named: "Workbook") else {
            if compound.stream(named: "Book") != nil { throw KlickError.unsupported("Excel 95 workbooks") }
            throw KlickError.unreadable(url.lastPathComponent)
        }
        var reader = BIFFReader(stream, name: url.lastPathComponent)
        return try reader.workbook()
    }
}

// MARK: - OLE2 compound file

/// Microsoft Compound File Binary format: a FAT file system inside the file. Only what's needed to
/// read a named stream from the root storage.
private struct CompoundFile {
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF

    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private var miniStream: [UInt8] = []
    private var entries: [(name: String, type: UInt8, start: UInt32, size: Int)] = []

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 512, bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else { return nil }
        self.bytes = bytes
        let sectorShift = Int(Self.u16(bytes, 0x1E))
        let miniShift = Int(Self.u16(bytes, 0x20))
        guard (7...16).contains(sectorShift), miniShift < sectorShift else { return nil }
        sectorSize = 1 << sectorShift
        miniSectorSize = 1 << miniShift
        miniCutoff = Int(Self.u32(bytes, 0x38))

        // The FAT's own sectors are listed in the header's DIFAT, continued in DIFAT sectors.
        var fatSectors: [UInt32] = (0..<109).map { Self.u32(bytes, 0x4C + $0 * 4) }
        var difat = Self.u32(bytes, 0x44)
        var guardCount = 0
        while difat < Self.endOfChain - 3, guardCount < 100_000 {
            let offset = (Int(difat) + 1) * sectorSize
            guard offset + sectorSize <= bytes.count else { break }
            let perSector = sectorSize / 4 - 1
            fatSectors += (0..<perSector).map { Self.u32(bytes, offset + $0 * 4) }
            difat = Self.u32(bytes, offset + perSector * 4)
            guardCount += 1
        }
        for sector in fatSectors where sector < Self.endOfChain - 3 {
            let offset = (Int(sector) + 1) * sectorSize
            guard offset + sectorSize <= bytes.count else { continue }
            fat += (0..<(sectorSize / 4)).map { Self.u32(bytes, offset + $0 * 4) }
        }

        let directory = chain(from: Self.u32(bytes, 0x30))
        for entry in stride(from: 0, to: directory.count - 127, by: 128) {
            let nameLength = min(Int(Self.u16(directory, entry + 0x40)), 64)
            let units = (0..<max(nameLength / 2 - 1, 0)).map { Self.u16(directory, entry + $0 * 2) }
            let size = Int(Self.u32(directory, entry + 0x78))
            entries.append((String(decoding: units, as: UTF16.self), directory[entry + 0x42], Self.u32(directory, entry + 0x74), size))
        }
        guard let root = entries.first, root.type == 5 else { return nil }

        let miniFatBytes = chain(from: Self.u32(bytes, 0x3C))
        miniFat = stride(from: 0, to: miniFatBytes.count - 3, by: 4).map { Self.u32(miniFatBytes, $0) }
        miniStream = chain(from: root.start)
    }

    /// Contents of a stream in the root storage (names compare case-insensitively).
    func stream(named name: String) -> [UInt8]? {
        guard let entry = entries.dropFirst().first(where: { $0.type == 2 && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        let data = entry.size < miniCutoff ? miniChain(from: entry.start) : chain(from: entry.start)
        return Array(data.prefix(entry.size))
    }

    private func chain(from start: UInt32) -> [UInt8] {
        var result: [UInt8] = []
        var sector = start
        var visited = 0
        while sector < Self.endOfChain - 3, Int(sector) < fat.count || fat.isEmpty, visited <= fat.count {
            let offset = (Int(sector) + 1) * sectorSize
            guard offset + sectorSize <= bytes.count else {
                if offset < bytes.count { result += bytes[offset...] }
                break
            }
            result += bytes[offset..<(offset + sectorSize)]
            guard Int(sector) < fat.count else { break }
            sector = fat[Int(sector)]
            visited += 1
        }
        return result
    }

    private func miniChain(from start: UInt32) -> [UInt8] {
        var result: [UInt8] = []
        var sector = start
        var visited = 0
        while sector < Self.endOfChain - 3, Int(sector) < miniFat.count, visited <= miniFat.count {
            let offset = Int(sector) * miniSectorSize
            guard offset + miniSectorSize <= miniStream.count else { break }
            result += miniStream[offset..<(offset + miniSectorSize)]
            sector = miniFat[Int(sector)]
            visited += 1
        }
        return result
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return freeSector }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

// MARK: - BIFF8 records

private struct BIFFReader {
    private let stream: [UInt8]
    private let name: String
    private var strings: [String] = []
    private var formats: [Int: String] = [:]
    private var cellFormats: [Int] = [] // XF index → number format id
    private var date1904 = false

    init(_ stream: [UInt8], name: String) {
        self.stream = stream
        self.name = name
    }

    private struct Record {
        let type: UInt16
        let data: ArraySlice<UInt8>
        let next: Int
    }

    private func record(at offset: Int) -> Record? {
        guard offset + 4 <= stream.count else { return nil }
        let type = CompoundFile.u16(stream, offset)
        let length = Int(CompoundFile.u16(stream, offset + 2))
        let end = min(offset + 4 + length, stream.count)
        return Record(type: type, data: stream[(offset + 4)..<end], next: offset + 4 + length)
    }

    mutating func workbook() throws -> SpreadsheetWorkbook {
        guard let bof = record(at: 0), bof.type == 0x0809 else { throw KlickError.unreadable(name) }
        guard value16(bof.data, 0) == 0x0600 else { throw KlickError.unsupported("Excel 95 workbooks") }

        // Workbook globals: string table, formats, date system and the list of sheets.
        var sheets: [(name: String, offset: Int)] = []
        var offset = bof.next
        while let record = record(at: offset) {
            offset = record.next
            switch record.type {
            case 0x000A: // EOF
                offset = stream.count
            case 0x002F: // FILEPASS
                throw KlickError.unsupported("Password-protected workbooks")
            case 0x0022: // DATEMODE
                date1904 = value16(record.data, 0) == 1
            case 0x041E: // FORMAT
                var reader = StringReader([record.data])
                let id = Int(reader.u16())
                formats[id] = reader.string(count: Int(reader.u16()))
            case 0x00E0: // XF
                cellFormats.append(Int(value16(record.data, 2)))
            case 0x0085: // BOUNDSHEET8
                guard record.data.count >= 8, record.data[record.data.startIndex + 5] == 0 else { continue } // worksheets only
                var reader = StringReader([record.data.dropFirst(6)])
                let count = Int(reader.u8())
                sheets.append((reader.string(count: count), Int(value32(record.data, 0))))
            case 0x00FC: // SST, continued in CONTINUE records
                var segments = [record.data.dropFirst(8)]
                var continuation = record.next
                while let next = self.record(at: continuation), next.type == 0x003C {
                    segments.append(next.data)
                    continuation = next.next
                }
                offset = continuation
                var reader = StringReader(segments)
                let count = Int(value32(record.data, 4))
                strings.reserveCapacity(min(count, 1_000_000))
                for _ in 0..<count where !reader.isAtEnd { strings.append(reader.richString()) }
            default:
                break
            }
        }

        let result = sheets.map { sheet in SpreadsheetSheet(name: sheet.name, rows: cells(from: sheet.offset)) }
        guard !result.isEmpty else { throw KlickError.unreadable(name) }
        return SpreadsheetWorkbook(sheets: result)
    }

    /// Cell records of the worksheet substream starting at `start` (embedded chart substreams are skipped).
    private func cells(from start: Int) -> [[SpreadsheetCell]] {
        var rows: [[SpreadsheetCell]] = []
        func set(_ row: Int, _ column: Int, _ value: SpreadsheetCell) {
            guard !value.isEmpty, row < 65_536, column < 256 else { return }
            if rows.count <= row { rows += Array(repeating: [], count: row + 1 - rows.count) }
            if rows[row].count <= column { rows[row] += Array(repeating: .empty, count: column + 1 - rows[row].count) }
            rows[row][column] = value
        }

        var depth = 0
        var offset = start
        var pendingString: (row: Int, column: Int)?
        while let record = record(at: offset) {
            offset = record.next
            let data = record.data
            switch record.type {
            case 0x0809: depth += 1; continue
            case 0x000A:
                depth -= 1
                if depth <= 0 { return rows }
                continue
            default: break
            }
            guard depth == 1 else { continue }
            let row = Int(value16(data, 0))
            let column = Int(value16(data, 2))
            let xf = Int(value16(data, 4))
            switch record.type {
            case 0x00FD: // LABELSST
                let index = Int(value32(data, 6))
                if strings.indices.contains(index) { set(row, column, .text(strings[index])) }
            case 0x0203: // NUMBER
                set(row, column, number(double(data, 6), xf: xf))
            case 0x027E: // RK
                set(row, column, number(rk(value32(data, 6)), xf: xf))
            case 0x00BD: // MULRK: (xf, rk) pairs for consecutive columns
                let pairs = (data.count - 6) / 6
                for index in 0..<max(pairs, 0) {
                    let base = 4 + index * 6
                    set(row, column + index, number(rk(value32(data, base + 2)), xf: Int(value16(data, base))))
                }
            case 0x0204: // LABEL
                var reader = StringReader([data.dropFirst(6)])
                set(row, column, .text(reader.string(count: Int(reader.u16()))))
            case 0x0205: // BOOLERR
                guard data.count >= 8 else { continue }
                let value = data[data.startIndex + 6]
                set(row, column, data[data.startIndex + 7] == 0 ? .bool(value != 0) : .text(errorText(value)))
            case 0x0006: // FORMULA: cached result
                guard data.count >= 14 else { continue }
                let base = data.startIndex + 6
                if data[base + 6] == 0xFF && data[base + 7] == 0xFF {
                    switch data[base] {
                    case 0: pendingString = (row, column) // value follows in a STRING record
                    case 1: set(row, column, .bool(data[base + 2] != 0))
                    case 2: set(row, column, .text(errorText(data[base + 2])))
                    default: break
                    }
                } else {
                    set(row, column, number(double(data, 6), xf: xf))
                }
            case 0x0207: // STRING
                if let target = pendingString {
                    var reader = StringReader([data])
                    set(target.row, target.column, .text(reader.string(count: Int(reader.u16()))))
                    pendingString = nil
                }
            default:
                break
            }
        }
        return rows
    }

    private func number(_ value: Double, xf: Int) -> SpreadsheetCell {
        guard cellFormats.indices.contains(xf), value >= 0 else { return .number(value) }
        let format = cellFormats[xf]
        guard let style = SpreadsheetXLSX.dateStyle(formatID: format, code: formats[format]) else { return .number(value) }
        return .date(date1904 ? value + 1462 : value, style)
    }

    /// RK: a compressed number — either a 30-bit integer or the top 30 bits of a double, optionally ×100.
    private func rk(_ raw: UInt32) -> Double {
        var value: Double
        if raw & 0x02 != 0 {
            value = Double(Int32(bitPattern: raw) >> 2)
        } else {
            value = Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32)
        }
        if raw & 0x01 != 0 { value /= 100 }
        return value
    }

    private func errorText(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "#NULL!"
        case 0x07: return "#DIV/0!"
        case 0x0F: return "#VALUE!"
        case 0x17: return "#REF!"
        case 0x1D: return "#NAME?"
        case 0x24: return "#NUM!"
        case 0x2A: return "#N/A"
        default: return "#ERROR!"
        }
    }

    private func value16(_ data: ArraySlice<UInt8>, _ offset: Int) -> UInt16 {
        let index = data.startIndex + offset
        guard index + 1 < data.endIndex else { return 0 }
        return UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private func value32(_ data: ArraySlice<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(value16(data, offset)) | UInt32(value16(data, offset + 2)) << 16
    }

    private func double(_ data: ArraySlice<UInt8>, _ offset: Int) -> Double {
        let low = UInt64(value32(data, offset))
        let high = UInt64(value32(data, offset + 4))
        return Double(bitPattern: low | high << 32)
    }
}

/// Reads BIFF8 strings that may be split across CONTINUE records: a string's character data
/// resumes in the next record with a fresh "high byte" flag.
private struct StringReader {
    private var segments: [ArraySlice<UInt8>]
    private var segment = 0
    private var position: Int

    init(_ segments: [ArraySlice<UInt8>]) {
        self.segments = segments.isEmpty ? [[]] : segments
        position = self.segments[0].startIndex
    }

    var isAtEnd: Bool {
        segment >= segments.count - 1 && position >= segments[segments.count - 1].endIndex
    }

    private mutating func advanceIfNeeded() -> Bool {
        while segment < segments.count, position >= segments[segment].endIndex {
            segment += 1
            guard segment < segments.count else { return false }
            position = segments[segment].startIndex
        }
        return segment < segments.count
    }

    mutating func u8() -> UInt8 {
        guard advanceIfNeeded() else { return 0 }
        defer { position += 1 }
        return segments[segment][position]
    }

    mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }

    mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }

    mutating func skip(_ count: Int) {
        for _ in 0..<max(count, 0) { _ = u8() }
    }

    /// XLUnicodeString body: a flags byte, then `count` characters.
    mutating func string(count: Int) -> String {
        characters(count, flags: u8())
    }

    /// XLUnicodeRichExtendedString (SST entries): count, flags, optional run/extension sizes, characters, then runs and extensions.
    mutating func richString() -> String {
        let count = Int(u16())
        let flags = u8()
        let runs = flags & 0x08 != 0 ? Int(u16()) : 0
        let extended = flags & 0x04 != 0 ? Int(u32()) : 0
        let text = characters(count, flags: flags)
        skip(runs * 4 + extended)
        return text
    }

    private mutating func characters(_ count: Int, flags: UInt8) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(count)
        var wide = flags & 0x01 != 0
        while units.count < count {
            if position >= segments[min(segment, segments.count - 1)].endIndex {
                // Character data continues in the next CONTINUE record, which starts with its own flags byte.
                segment += 1
                guard segment < segments.count else { break }
                position = segments[segment].startIndex
                wide = u8() & 0x01 != 0
                continue
            }
            if wide {
                units.append(u16())
            } else {
                units.append(UInt16(u8()))
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
