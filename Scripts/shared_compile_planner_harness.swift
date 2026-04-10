import Foundation

@main
struct SharedCompilePlannerHarnessMain {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: SharedCompilePlannerHarnessMain <input.json>\n", stderr)
            exit(2)
        }

        let inputPath = CommandLine.arguments[1]
        let inputData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let input = try JSONDecoder().decode(SharedCompilePlannerInput.self, from: inputData)
        let plan = SharedCompilePlanner.makePlan(input: input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let outputData = try encoder.encode(plan)
        FileHandle.standardOutput.write(outputData)
    }
}
