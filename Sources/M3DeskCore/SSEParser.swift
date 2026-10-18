import Foundation

struct SSEEvent: Equatable, Sendable {
    let event: String
    let id: String?
    let data: String
}

/// Incremental UTF-8 SSE framing. Handles CR, LF, CRLF across chunks and multiline data.
/// EOF does not dispatch incomplete events: a blank line is required by the SSE protocol.
struct SSEParser: Sendable {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventName = ""
    private var lastEventID: String?
    private var skipLF = false
    private var firstLine = true
    private var eventBytes = 0
    let maximumEventBytes: Int

    init(maximumEventBytes: Int = 2 * 1024 * 1024) { self.maximumEventBytes = maximumEventBytes }

    mutating func feed(_ chunk: Data) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in chunk {
            if skipLF { skipLF = false; if byte == 10 { continue } }
            if byte == 13 || byte == 10 {
                if let event = try consumeLine() { events.append(event) }
                skipLF = byte == 13
            } else {
                line.append(byte)
                guard line.count + eventBytes <= maximumEventBytes else { throw MCPError.responseTooLarge }
            }
        }
        return events
    }

    private mutating func consumeLine() throws -> SSEEvent? {
        guard var text = String(data: line, encoding: .utf8) else { throw MCPError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if text.hasPrefix("\u{FEFF}") { text.removeFirst() } }
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); eventName = ""; eventBytes = 0 }
            guard !dataLines.isEmpty else { return nil }
            return SSEEvent(event: eventName.isEmpty ? "message" : eventName, id: lastEventID, data: dataLines.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "data":
            eventBytes += value.utf8.count + 1
            guard eventBytes <= maximumEventBytes else { throw MCPError.responseTooLarge }
            dataLines.append(value)
        case "event": eventName = value
        case "id": if !value.contains("\0") { lastEventID = value }
        default: break
        }
        return nil
    }
}
