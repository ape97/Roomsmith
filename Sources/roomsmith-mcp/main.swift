import Foundation
import RoomsmithCore
import RoomsmithIPC

let usage = """
roomsmith-mcp \(RoomsmithMCP.version) - MCP bridge and CLI for the running Roomsmith app

Usage:
  roomsmith-mcp                         MCP server on stdin/stdout
  roomsmith-mcp tools                   list available tools
  roomsmith-mcp call <tool> ['<json>']  call a tool, print the result as JSON

Options:
  --client <id>     client id reported to the app (default: cli, or mcp in server mode)
  --socket <path>   socket path (default: ROOMSMITH_SOCKET or Application Support)
  --help, --version
"""

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

/// Serializes writes to stdout so concurrent answers never interleave.
actor StdoutWriter {
    func write(_ text: String) {
        var data = Data(text.utf8)
        data.append(10)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(1, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                return
            }
        }
    }
}

struct Options {
    var client: String?
    var socket: String?
    var help = false
    var version = false
    var positional: [String] = []
}

func parseOptions(_ args: [String]) -> Options? {
    var options = Options()
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--help", "-h": options.help = true
        case "--version": options.version = true
        case "--client", "--socket":
            guard index + 1 < args.count else { printError("Missing value for \(arg)"); return nil }
            index += 1
            if arg == "--client" { options.client = args[index] } else { options.socket = args[index] }
        default:
            if arg.hasPrefix("--") { printError("Unknown option \(arg)"); return nil }
            options.positional.append(arg)
        }
        index += 1
    }
    return options
}

func makeClient(_ options: Options, defaultClient: String) -> AgentSocketClient {
    let socket = options.socket ?? AgentPaths.socketURL.path
    return AgentSocketClient(
        socketPath: socket,
        tokenProvider: { try AgentToken.load(at: AgentPaths.tokenURL) },
        clientId: options.client ?? defaultClient)
}

func jsonText(_ error: AgentError) -> String {
    (try? JSONValue(encoding: error))?.jsonString(pretty: true) ?? "\(error)"
}

func serve(_ options: Options) async -> Int32 {
    let bridge = MCPBridge(transport: makeClient(options, defaultClient: "mcp"))
    let writer = StdoutWriter()
    printError("roomsmith-mcp \(RoomsmithMCP.version) ready (stdio)")
    await withTaskGroup(of: Void.self) { group in
        while let line = readLine(strippingNewline: true) {
            if line.allSatisfy(\.isWhitespace) { continue }
            group.addTask {
                if let answer = await bridge.handle(line: line) { await writer.write(answer) }
            }
        }
    }
    return 0
}

func listTools(_ options: Options) async -> Int32 {
    do {
        let raw = try await makeClient(options, defaultClient: "cli").call(agentListToolsName)
        let tools = try raw.decode([ToolDescriptor].self)
        let width = max(4, tools.map(\.name.count).max() ?? 4)
        writeStdout("NAME".padding(toLength: width, withPad: " ", startingAt: 0) + "  MODE  DESCRIPTION")
        for tool in tools.sorted(by: { $0.name < $1.name }) {
            let summary = tool.description.split(separator: "\n").first.map(String.init) ?? ""
            writeStdout(tool.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + (tool.readOnly ? "ro  " : "rw  ") + "  " + summary)
        }
        return 0
    } catch let error as AgentError {
        printError(jsonText(error))
        return 1
    } catch {
        printError(jsonText(AgentError(code: AgentError.internal, message: "\(error)")))
        return 1
    }
}

func callTool(_ options: Options) async -> Int32 {
    let positional = options.positional
    guard positional.count >= 2, positional.count <= 3 else {
        printError(usage)
        return 2
    }
    var arguments = JSONValue.object([:])
    if positional.count == 3 {
        guard let parsed = try? JSONValue.parse(Data(positional[2].utf8)) else {
            printError(jsonText(AgentError(code: AgentError.invalidArgument, message: "Arguments are not valid JSON")))
            return 1
        }
        arguments = parsed
    }
    do {
        let result = try await makeClient(options, defaultClient: "cli").call(positional[1], arguments: arguments)
        writeStdout(result.jsonString(pretty: true))
        return 0
    } catch let error as AgentError {
        printError(jsonText(error))
        return 1
    } catch {
        printError(jsonText(AgentError(code: AgentError.internal, message: "\(error)")))
        return 1
    }
}

func run() async -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    guard let options = parseOptions(Array(CommandLine.arguments.dropFirst())) else {
        printError(usage)
        return 2
    }
    if options.help { writeStdout(usage); return 0 }
    if options.version { writeStdout("roomsmith-mcp \(RoomsmithMCP.version)"); return 0 }
    switch options.positional.first {
    case nil: return await serve(options)
    case "tools": return await listTools(options)
    case "call": return await callTool(options)
    default:
        printError("Unknown command \(options.positional[0])\n" + usage)
        return 2
    }
}

exit(await run())
