import Foundation

enum OutputFormatter {
    static func formatTranscription(_ data: Data, json: Bool) -> String {
        if json {
            return prettyJSON(data)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            return prettyJSON(data)
        }
        return text
    }

    static func formatStatus(_ data: Data, json: Bool) -> String {
        if json {
            return prettyJSON(data)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else {
            return prettyJSON(data)
        }
        let engine = obj["engine"] as? String ?? "unknown"
        let model = obj["model"] as? String

        var parts = [String]()
        parts.append(status == "ready" ? "Ready" : "No model loaded")
        if let model {
            parts.append("\(engine) (\(model))")
        } else {
            parts.append(engine)
        }

        return parts.joined(separator: " - ")
    }

    static func formatModels(_ data: Data, json: Bool) -> String {
        if json {
            return prettyJSON(data)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else {
            return prettyJSON(data)
        }

        if models.isEmpty {
            return "No models available."
        }

        // Calculate column widths
        var idWidth = 2, engineWidth = 6, nameWidth = 4, statusWidth = 6
        for model in models {
            let id = model["id"] as? String ?? ""
            let engine = model["engine"] as? String ?? ""
            let name = model["name"] as? String ?? ""
            let status = model["status"] as? String ?? ""
            idWidth = max(idWidth, id.count)
            engineWidth = max(engineWidth, engine.count)
            nameWidth = max(nameWidth, name.count)
            statusWidth = max(statusWidth, status.count)
        }

        var lines = [String]()
        lines.append(
            "ID".padding(toLength: idWidth, withPad: " ", startingAt: 0) + "  " +
            "ENGINE".padding(toLength: engineWidth, withPad: " ", startingAt: 0) + "  " +
            "NAME".padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  " +
            "STATUS"
        )
        lines.append(String(repeating: "-", count: idWidth + engineWidth + nameWidth + statusWidth + 6))

        for model in models {
            let id = (model["id"] as? String ?? "").padding(toLength: idWidth, withPad: " ", startingAt: 0)
            let engine = (model["engine"] as? String ?? "").padding(toLength: engineWidth, withPad: " ", startingAt: 0)
            let name = (model["name"] as? String ?? "").padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let status = model["status"] as? String ?? ""
            let selected = (model["selected"] as? Bool ?? false) ? " *" : ""
            lines.append("\(id)  \(engine)  \(name)  \(status)\(selected)")
        }

        return lines.joined(separator: "\n")
    }

    private static func prettyJSON(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: pretty, encoding: .utf8) {
            return str
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
