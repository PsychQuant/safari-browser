import ArgumentParser
import Foundation
import MLXLMCommon
import MLXHuggingFace
import MLXVLM
import Tokenizers
import Hub
import HuggingFace

@main
struct SafariVision: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "safari-vision",
        abstract: "Analyze screenshots using local VLM (MLXVLM on Apple Silicon)",
        subcommands: [
            AnalyzeCommand.self,
            SetupCommand.self,
        ]
    )
}

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze a screenshot image with a text prompt"
    )

    @Argument(help: "Path to the image file")
    var imagePath: String

    @Argument(help: "Prompt describing what to analyze")
    var prompt: String = "Describe the current state of this webpage in one sentence."

    @Option(name: .long, help: "Model ID (default: mlx-community/Qwen2.5-VL-3B-Instruct-4bit)")
    var model: String = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"

    @Option(name: .long, help: "Maximum tokens to generate")
    var maxTokens: Int = 200

    func run() async throws {
        let expandedPath = (imagePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            FileHandle.standardError.write(Data("Error: Image not found: \(imagePath)\n".utf8))
            throw ExitCode.failure
        }

        let config = ModelConfiguration(id: model)
        let container = try await #huggingFaceLoadModelContainer(configuration: config)
        let session = ChatSession(container)

        let imageURL = URL(fileURLWithPath: expandedPath)
        let answer = try await session.respond(
            to: prompt,
            image: .url(imageURL)
        )

        print(answer)
    }
}

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Pre-download the VLM model"
    )

    @Option(name: .long, help: "Model ID to download")
    var model: String = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"

    func run() async throws {
        print("Downloading model: \(model)...")
        let config = ModelConfiguration(id: model)
        let _ = try await #huggingFaceLoadModelContainer(configuration: config)
        print("Model downloaded and ready.")
    }
}
