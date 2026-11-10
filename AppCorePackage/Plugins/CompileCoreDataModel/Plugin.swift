import Foundation
import PackagePlugin

enum CompileCoreDataModelError: Error, CustomStringConvertible {
    case missingCoreDataModel(String)

    var description: String {
        switch self {
        case .missingCoreDataModel(let target):
            "No .xcdatamodeld file found in source target \(target)."
        }
    }
}

@main
struct CompileCoreDataModel: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else { return [] }
        let sourceDir = sourceTarget.directoryURL
        let entries = try FileManager.default.contentsOfDirectory(atPath: sourceDir.path)
        let modelURLs = entries
            .filter { $0.hasSuffix(".xcdatamodeld") }
            .map { sourceDir.appendingPathComponent($0) }
        guard !modelURLs.isEmpty else {
            throw CompileCoreDataModelError.missingCoreDataModel(sourceTarget.name)
        }

        return modelURLs.map { modelURL in
            let stem = modelURL.deletingPathExtension().lastPathComponent
            let workDir = context.pluginWorkDirectoryURL
            return .prebuildCommand(
                displayName: "Compile \(modelURL.lastPathComponent)",
                executable: URL(filePath: "/usr/bin/xcrun"),
                arguments: ["momc", modelURL.path, workDir.path],
                outputFilesDirectory: workDir.appendingPathComponent("\(stem).momd")
            )
        }
    }
}
