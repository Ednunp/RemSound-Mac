import Foundation

@main
struct RenderManual {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 || args.count == 4 && args[3] == "--check" else {
            throw NSError(domain: "RenderManual", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: RenderManual README.md Manual.html Manual.txt [--check]"])
        }
        let source = try String(contentsOfFile: args[0], encoding: .utf8)
        for (path, text) in [(args[1], ManualHTML.render(source)), (args[2], ManualHTML.plainText(source))] {
            if args.count == 4 {
                guard try String(contentsOfFile: path, encoding: .utf8) == text else {
                    throw NSError(domain: "RenderManual", code: 1, userInfo: [NSLocalizedDescriptionKey: "The generated manual is stale. Regenerate its HTML and text exports."])
                }
            } else {
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
