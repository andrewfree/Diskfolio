import Foundation

@main
struct VerifyCleanupCommand {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst().prefix { $0 != "-AppleLanguages" })
        let root = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let recovery = root.appendingPathComponent("Recovery", isDirectory: true)
        exit(CleanupCommand.run(Array(arguments.dropFirst()), roots: [root], recovery: recovery) ?? 64)
    }
}
