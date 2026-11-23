import Foundation

@main
struct VerifyInventory {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let standard = KeepPreference(architecture: "arm64", languages: ["en-US"])
        let report = try AppInventory.scan(roots: [root], preference: standard, appLanguagePreferences: { _ in [] })
        let sizes = Dictionary(uniqueKeysWithValues: report.apps.map { ($0.name, $0.size) })
        precondition(report.scanned == 4 && report.unreadable == 0)
        precondition(sizes["Atlas"] == InventorySize(architecture: 10_240_000, language: 4_200_000))
        precondition(sizes["Beacon"] == InventorySize(architecture: 3_276_800, language: 5_750_000))
        precondition(sizes["Legacy"] == InventorySize(architecture: 0, language: 200_000))
        precondition(sizes["Language Workbench"] == InventorySize(architecture: 0, language: 15_200_000))

        let override = try AppInventory.scan(roots: [root], preference: standard, appLanguagePreferences: { identifier in
            identifier == "local.diskfolio.fixture.languages" ? ["fr-CA", "nb", "fil", "zh-Hant"] : []
        })
        precondition(override.scanned == 4 && !override.apps.contains { $0.name == "Language Workbench" })
        precondition(KeepPreference.languageFamily("neuter") == nil)

        let model = InventoryModel(roots: [root])
        precondition(model.rankedApps(report.apps).map(\.name) == ["Language Workbench", "Atlas", "Beacon", "Legacy"])
        model.selection = [.architecture]
        precondition(model.rankedApps(report.apps).map(\.name) == ["Atlas", "Beacon"])
        model.selection = [.language]
        precondition(model.rankedApps(report.apps).map(\.name) == ["Language Workbench", "Beacon", "Atlas", "Legacy"])
        model.selection = []
        precondition(model.rankedApps(report.apps).isEmpty)
        print("Verified app ranking, Rosetta-dependent architecture, app override and alias retention, unknown and unmatched locales, symlink-safe discovery, and hard links.")
    }
}
