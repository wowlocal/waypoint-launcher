import Foundation

/// The game-service wire format, as far as WoW account discovery needs it.
/// A frame is a two-byte big-endian header length, a protobuf header and a
/// body of the size the header gives. Every size and count read from the
/// server is checked against a bound before anything is allocated or awaited.
enum WoWAccountWire {
    enum Failure: Error { case malformed, oversized }

    static let maximumHeader = 8192
    static let maximumBody = 1_048_576

    /// `service` of a frame that answers one of ours.
    static let responseService: UInt64 = 254
    /// "WoW" as the four-character code the service uses for the game.
    static let program: UInt64 = 5_730_135

    enum Service {
        static let authentication: UInt32 = 0xc02f_8216
        static let authenticationListener: UInt32 = 0x9da8_116b
        // The same v2 listener's name hash, not ChallengeListener.
        // TrinityCore Client/api/client/v2/authentication_listener.pb.h
        static let authenticationListenerNameHash: UInt32 = 0xecb8_b826
        static let account: UInt32 = 0x22dc_2464
    }

    // MARK: Messages

    /// A decoded message. Fields nobody asks for are kept and ignored; a
    /// field that is asked for must be there once, with the expected type.
    struct Message {
        private let fields: [Int: [ProtoReader.Value]]

        init(_ data: Data) throws {
            guard data.count <= maximumBody else { throw Failure.oversized }
            do { fields = try ProtoReader(data).fields() } catch { throw Failure.malformed }
            guard fields.keys.allSatisfy({ $0 > 0 }) else { throw Failure.malformed }
        }

        var fieldNumbers: [Int] { Array(fields.keys) }
        func has(_ field: Int) -> Bool { fields[field] != nil }

        /// A number, however the wire spelled it (varint or fixed).
        func uint(_ field: Int, default fallback: UInt64? = nil) throws -> UInt64 {
            guard let values = fields[field] else {
                guard let fallback else { throw Failure.malformed }
                return fallback
            }
            guard values.count == 1 else { throw Failure.malformed }
            switch values[0] {
            case .varint(let value), .fixed64(let value): return value
            case .fixed32(let value): return UInt64(value)
            case .bytes: throw Failure.malformed
            }
        }

        func bytes(_ field: Int) throws -> Data {
            guard let values = fields[field], values.count == 1, case .bytes(let data) = values[0] else {
                throw Failure.malformed
            }
            return data
        }

        func message(_ field: Int) throws -> Message { try Message(bytes(field)) }

        /// Every occurrence of a repeated length-delimited field, in order.
        func repeatedBytes(_ field: Int) throws -> [Data] {
            try (fields[field] ?? []).map {
                guard case .bytes(let data) = $0 else { throw Failure.malformed }
                return data
            }
        }
    }

    // MARK: Frames

    struct Header {
        var service: UInt64
        var method: UInt64
        var token: UInt64
        var size: Int
        var status: UInt64
        var serviceHash: UInt32?

        var isResponse: Bool { service == responseService }

        init(_ data: Data) throws {
            let message = try Message(data)
            // Present or not, these may only ever be single numbers.
            for field in [1, 2, 3, 5, 6, 9, 11] where message.has(field) { _ = try message.uint(field) }
            service = try message.uint(1)
            method = try message.uint(2, default: 0)
            token = try message.uint(3)
            status = try message.uint(6, default: 0)
            let size = try message.uint(5, default: 0)
            guard size <= UInt64(maximumBody) else { throw Failure.oversized }
            self.size = Int(size)
            if message.has(11) {
                guard let hash = UInt32(exactly: try message.uint(11)) else { throw Failure.malformed }
                serviceHash = hash
            }
        }
    }

    /// One request frame. Requests are addressed by service hash; only the
    /// opening connect goes without one.
    static func frame(method: UInt64, token: UInt64, hash: UInt32? = nil, body: Data = Data()) throws -> Data {
        guard body.count <= maximumBody else { throw Failure.oversized }
        var header = ProtoWriter()
        header.varint(1, 0)
        header.varint(2, method)
        header.varint(3, token)
        header.varint(5, UInt64(body.count))
        var bytes = header.data
        if let hash {
            bytes.append(11 << 3 | 5) // field 11, fixed32
            bytes.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: hash >> ($0 * 8)) })
        }
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)]) + bytes + body
    }

    /// The header length that the two-byte prefix announces.
    static func headerLength(_ prefix: Data) throws -> Int {
        guard prefix.count == 2 else { throw Failure.malformed }
        let length = Int(prefix[prefix.startIndex]) << 8 | Int(prefix[prefix.startIndex + 1])
        guard length > 0 else { throw Failure.malformed }
        guard length <= maximumHeader else { throw Failure.oversized }
        return length
    }

    // MARK: Requests

    static var connectRequest: Data {
        var body = ProtoWriter()
        body.varint(3, 1)
        return body.data
    }

    /// Signs in with the web login's ticket, as the game itself does.
    static func logonRequest(token: LoginToken, build: UInt64) -> Data {
        var body = ProtoWriter()
        body.varint(1, program)
        body.string(2, "Mc64")
        body.string(3, "enUS")
        body.varint(4, build)
        body.message(10) { $0.string(1, token.value) }
        return body.data
    }

    static func accountDetailsRequest(handle: Data) -> Data {
        var body = ProtoWriter()
        body.bytes(1, handle)
        return body.data
    }

    // MARK: Replies

    /// A licence as the account list names it: an id, the game it is for
    /// and the region it plays in. `raw` is sent back as is to ask for details.
    struct Handle {
        var id: UInt64
        var program: UInt64
        var region: UInt64
        var raw: Data

        init(_ data: Data) throws {
            let message = try Message(data)
            id = try message.uint(1)
            program = try message.uint(2)
            region = try message.uint(3)
            guard id > 0, program <= UInt64(UInt32.max), region <= UInt64(UInt32.max) else { throw Failure.malformed }
            raw = data
        }
    }

    static func handles(inAccountList body: Data, maximum: Int) throws -> [Handle] {
        let links = try Message(body).message(1).repeatedBytes(1)
        guard links.count <= maximum else { throw Failure.oversized }
        return try links.map(Handle.init)
    }

    static func accountDetails(_ body: Data) throws -> (owner: UInt64, name: Data) {
        let info = try Message(body).message(1)
        return (try info.uint(1), try info.bytes(2))
    }
}
