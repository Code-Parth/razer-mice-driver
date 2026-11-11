import Foundation

// Razer's Bluetooth mice take settings over a vendor GATT service, not HID feature
// reports. Wire format follows the OpenSnek project's BLE protocol notes
// (github.com/gh123man/OpenSnek, docs/protocol/BLE_PROTOCOL.md).

enum VendorGATT {
    static let service = "52401523-F97C-7F90-0E7F-6C6F4E36DB1C"
    static let write = "52401524-F97C-7F90-0E7F-6C6F4E36DB1C"
    static let notify = "52401525-F97C-7F90-0E7F-6C6F4E36DB1C"
}

struct VendorKey: Hashable {
    let bytes: [UInt8]

    init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) {
        bytes = [b0, b1, b2, b3]
    }

    static let dpiStagesGet = VendorKey(0x0B, 0x84, 0x01, 0x00)
    static let dpiStagesSet = VendorKey(0x0B, 0x04, 0x01, 0x00)
    static let batteryRaw = VendorKey(0x05, 0x81, 0x00, 0x01)

    static func buttonGet(slot: UInt8) -> VendorKey { VendorKey(0x08, 0x84, 0x01, slot) }
    static func buttonSet(slot: UInt8) -> VendorKey { VendorKey(0x08, 0x04, 0x01, slot) }
}

enum VendorStatus: UInt8 {
    case success = 0x02
    case failure = 0x03
    case badParameter = 0x05
}

enum VendorFrame {
    static let chunkLength = 20

    /// One 8-byte header, then the payload split into 20-byte characteristic writes.
    static func request(id: UInt8, key: VendorKey, payload: [UInt8] = []) -> [Data] {
        var frames = [Data([id, UInt8(payload.count), 0x00, 0x00] + key.bytes)]
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkLength, payload.count)
            frames.append(Data(payload[offset..<end]))
            offset = end
        }
        return frames
    }
}

/// Reassembles one response: a notify header echoing the request ID, then
/// continuation frames carrying `payload_length` bytes.
struct VendorResponse {
    enum Progress: Equatable {
        case waiting
        case done([UInt8])
        case failed(status: UInt8)
    }

    let requestID: UInt8
    private var header: [UInt8] = []
    private var expected: Int?
    private var body: [UInt8] = []

    init(requestID: UInt8) {
        self.requestID = requestID
    }

    var hasHeader: Bool { expected != nil }

    mutating func consume(_ frame: [UInt8]) -> Progress {
        guard let expected else {
            guard frame.count >= 8, frame[0] == requestID, let status = VendorStatus(rawValue: frame[7]) else {
                return .waiting
            }
            guard status == .success else { return .failed(status: frame[7]) }
            header = frame
            self.expected = Int(frame[1])
            return frame[1] == 0 ? .done([]) : .waiting
        }
        body += frame
        return body.count >= expected ? .done(Array(body.prefix(expected))) : .waiting
    }

    /// Some firmware packs a short payload into the header frame itself and sends
    /// no continuation. Only meaningful once the link has gone idle.
    var embeddedPayload: [UInt8]? {
        guard let expected, body.isEmpty, header.count >= 8 + expected else { return nil }
        return Array(header[8..<(8 + expected)])
    }
}

struct DPIStage: Equatable {
    var id: UInt8
    var x: Int
    var y: Int
}

struct DPITable: Equatable {
    static let maxStages = 5
    /// DeathAdder V2 X HyperSpeed sensor ceiling.
    static let range = 100...14_000

    var stages: [DPIStage]
    var activeIndex: Int
    /// Opaque trailing byte of the last entry; the firmware expects it echoed back.
    var marker: UInt8 = 0x03

    init(stages: [DPIStage], activeIndex: Int, marker: UInt8 = 0x03) {
        self.stages = stages
        self.activeIndex = activeIndex
        self.marker = marker
    }

    /// `[active][count]` then 7-byte entries `[id][x_le16][y_le16][00][marker]`.
    init?(payload: [UInt8]) {
        guard payload.count >= 7 else { return nil }
        let count = Int(payload[1])
        guard (1...Self.maxStages).contains(count) else { return nil }

        var stages: [DPIStage] = []
        var marker: UInt8 = 0x03
        for index in 0..<count {
            let offset = 2 + index * 7
            guard offset + 4 < payload.count else { break }
            let x = Int(payload[offset + 1]) | Int(payload[offset + 2]) << 8
            let y = Int(payload[offset + 3]) | Int(payload[offset + 4]) << 8
            stages.append(DPIStage(id: payload[offset], x: x, y: y))
            if offset + 6 < payload.count { marker = payload[offset + 6] }
        }
        guard stages.count == count, stages.allSatisfy({ Self.range.contains($0.x) && Self.range.contains($0.y) }) else {
            return nil
        }

        // The active byte is a stage-ID token, not an index.
        let token = payload[0]
        if let match = stages.firstIndex(where: { $0.id == token }) {
            activeIndex = match
        } else if (1...count).contains(Int(token)) {
            activeIndex = Int(token) - 1
        } else {
            activeIndex = min(Int(token), count - 1)
        }
        self.stages = stages
        self.marker = marker
    }

    /// Writes are always the fixed 38-byte, five-entry form, whatever the visible count.
    var payload: [UInt8] {
        var entries = Array(stages.prefix(Self.maxStages))
        while entries.count < Self.maxStages {
            var filler = entries[entries.count - 1]
            filler.id = Self.unusedID(in: entries)
            entries.append(filler)
        }
        let active = min(max(activeIndex, 0), stages.count - 1)
        var out: [UInt8] = [entries[active].id, UInt8(min(stages.count, Self.maxStages))]
        for (index, stage) in entries.enumerated() {
            let x = min(max(stage.x, Self.range.lowerBound), Self.range.upperBound)
            let y = min(max(stage.y, Self.range.lowerBound), Self.range.upperBound)
            out += [stage.id, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8), 0x00]
            out.append(index == Self.maxStages - 1 ? marker : 0x00)
        }
        out.append(0x00)
        return out
    }

    /// The stages the mouse ships with, per Razer's guide: 1600 is the default.
    /// Stage IDs and the marker are carried over from the table the mouse holds.
    static func factory(replacing current: DPITable?) -> DPITable {
        let values = [400, 800, 1600, 3200, 6400]
        let held = current?.stages.map(\.id) ?? []
        let ids = held.count == values.count ? held : Array(1...UInt8(values.count))
        return DPITable(
            stages: zip(ids, values).map { DPIStage(id: $0, x: $1, y: $1) },
            activeIndex: 2,
            marker: current?.marker ?? 0x03
        )
    }

    static func unusedID(in stages: [DPIStage]) -> UInt8 {
        let used = Set(stages.map(\.id))
        return (0...UInt8.max).first { !used.contains($0) } ?? 0
    }
}
