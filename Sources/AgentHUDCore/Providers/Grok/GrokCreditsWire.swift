import Foundation

/// The Grok billing descriptor's exact config / current-period fields. The CLI JSON proxy can omit usage;
/// a complete gRPC response can confirm a proto3 zero only within an active weekly or monthly period.
/// Protocol reference: CodexBar GrokWebBillingFetcher (MIT) and grok.com's public billing descriptor.
enum GrokCreditsWire {
    struct Reading {
        let used: Double
        let start: Date?
        let end: Date?
        let periodType: String?
        var duration: TimeInterval? { ProviderDate.period(start: start, end: end) }
    }

    static func fetch(http: ProviderHTTP, token: String) async throws -> Reading {
        var request = URLRequest(url: URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        // Request field 1 is exclude_legacy_monthly_usage, explicitly false.
        request.httpBody = Data([0, 0, 0, 0, 2, 8, 0])
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        return try parse(await http.send(request))
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> Reading {
        let root = try fields(payload(data))
        let config = try fields(message(root, number: 1))
        let percentages = config.filter { $0.number == 1 }
        guard percentages.count <= 1 else { throw ProviderFailure.format }
        let used: Double?
        if let field = percentages.first {
            guard field.wire == 5, let raw = field.value else { throw ProviderFailure.format }
            let value = Double(Float(bitPattern: UInt32(raw)))
            guard value.isFinite, (0...100).contains(value) else { throw ProviderFailure.format }
            used = value
        } else { used = nil }
        var start: Date?, end: Date?, type: String?
        if config.contains(where: { $0.number == 8 }) {
            let period = try fields(message(config, number: 8))
            let kinds = period.filter { $0.number == 1 }
            guard kinds.count <= 1, kinds.isEmpty || kinds[0].wire == 0 else { throw ProviderFailure.format }
            type = switch kinds.first?.value {
            case 1: "USAGE_PERIOD_TYPE_WEEKLY"
            case 2: "USAGE_PERIOD_TYPE_MONTHLY"
            default: nil
            }
            if period.contains(where: { $0.number == 2 }) { start = try timestamp(message(period, number: 2)) }
            if period.contains(where: { $0.number == 3 }) { end = try timestamp(message(period, number: 3)) }
        }
        if let used { return Reading(used: used, start: start, end: end, periodType: type) }
        // A period-only proxy answer does not prove zero. This interpretation is restricted to the
        // actual complete protobuf, where the declared float defaults to zero, with an active period.
        guard type != nil, let start, let end, start <= now, now < end else { throw ProviderFailure.format }
        for product in config.filter({ $0.number == 7 }) {
            guard product.wire == 2, let data = product.data,
                  try !fields(data).contains(where: { $0.number == 2 }) else { throw ProviderFailure.format }
        }
        return Reading(used: 0, start: start, end: end, periodType: type)
    }

    private static func payload(_ data: Data) throws -> Data {
        guard let first = data.first else { throw ProviderFailure.format }
        guard first == 0 || first == 0x80 else { return data }
        let bytes = [UInt8](data)
        var offset = 0, messages: [Data] = []
        while offset < bytes.count {
            guard bytes.count - offset >= 5 else { throw ProviderFailure.format }
            let flag = bytes[offset]
            guard flag == 0 || flag == 0x80 else { throw ProviderFailure.format }
            let count = (Int(bytes[offset + 1]) << 24) | (Int(bytes[offset + 2]) << 16)
                | (Int(bytes[offset + 3]) << 8) | Int(bytes[offset + 4])
            offset += 5
            guard count <= bytes.count - offset else { throw ProviderFailure.format }
            let frame = Data(bytes[offset..<(offset + count)])
            if flag == 0 { messages.append(frame) }
            else {
                guard let text = String(data: frame, encoding: .utf8) else { throw ProviderFailure.format }
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2 else { throw ProviderFailure.format }
                    if parts[0].lowercased() == "grpc-status", parts[1] != "0" { throw ProviderFailure.format }
                }
            }
            offset += count
        }
        guard messages.count == 1 else { throw ProviderFailure.format }
        return messages[0]
    }

    private struct Field {
        let number: UInt64
        let wire: UInt64
        var value: UInt64? = nil
        var data: Data? = nil
    }

    private static func fields(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var offset = 0, result: [Field] = []
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw ProviderFailure.format }
                let byte = bytes[offset]; offset += 1
                guard index < 9 || byte <= 1 else { throw ProviderFailure.format }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte & 0x80 == 0 { return value }
            }
            throw ProviderFailure.format
        }
        while offset < bytes.count {
            let tag = try varint(), number = tag >> 3, wire = tag & 7
            guard number > 0, number <= 536_870_911 else { throw ProviderFailure.format }
            switch wire {
            case 0: result.append(Field(number: number, wire: wire, value: try varint()))
            case 1, 5:
                let count = wire == 1 ? 8 : 4
                guard count <= bytes.count - offset else { throw ProviderFailure.format }
                let value = (0..<count).reduce(UInt64(0)) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
                offset += count
                result.append(Field(number: number, wire: wire, value: value))
            case 2:
                guard let count = try Int(exactly: varint()), count <= bytes.count - offset else { throw ProviderFailure.format }
                result.append(Field(number: number, wire: wire, data: Data(bytes[offset..<(offset + count)])))
                offset += count
            default: throw ProviderFailure.format
            }
        }
        return result
    }

    private static func message(_ fields: [Field], number: UInt64) throws -> Data {
        let values = fields.filter { $0.number == number }
        guard values.count == 1, values[0].wire == 2, let data = values[0].data else { throw ProviderFailure.format }
        return data
    }

    private static func timestamp(_ data: Data) throws -> Date {
        let values = try fields(data), seconds = values.filter { $0.number == 1 }, nanos = values.filter { $0.number == 2 }
        guard seconds.count == 1, seconds[0].wire == 0, let value = seconds[0].value,
              value <= 253_402_300_799, nanos.count <= 1,
              nanos.isEmpty || (nanos[0].wire == 0 && (nanos[0].value ?? UInt64.max) <= 999_999_999)
        else { throw ProviderFailure.format }
        return Date(timeIntervalSince1970: Double(value) + Double(nanos.first?.value ?? 0) / 1_000_000_000)
    }
}
