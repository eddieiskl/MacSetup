import Foundation
import MCP
import MacSetupCore

/// MacSetupMCP — an MCP adapter over MacSetupCore.
///
/// Every tool here is read-only: it inspects the Mac and the catalogue and
/// reports back, never installs, updates, applies a tweak, or removes
/// anything. That split is deliberate (see docs/architecture-next.md) —
/// mutating MacSetup's Desired State plan (`create_remediation_plan`) and
/// anything that actually runs `InstallEngine` are follow-ups, added only
/// once these read tools are proven out. There is no generic shell-execution
/// tool here, and none is planned.

private func emptyObjectSchema(description: String) -> Value {
    .object([
        "type": .string("object"),
        "description": .string(description),
        "properties": .object([:]),
    ])
}

private let tools: [Tool] = [
    Tool(
        name: "get_doctor_report",
        description: """
        Run MacSetup Doctor's read-only health checks on this Mac: macOS version, \
        architecture, free disk space, FileVault, Gatekeeper, System Integrity \
        Protection, the Application Firewall, a pending macOS update, how many \
        catalogue apps are outdated, and (on Apple Silicon) which installed apps \
        are Intel-only and likely need Rosetta. Every check is read-only; a check \
        that can't get a clean answer reports "unknown" rather than a guess.
        """,
        inputSchema: emptyObjectSchema(description: "No arguments.")
    ),
    Tool(
        name: "compare_desired_state",
        description: """
        Compare a saved MacSetup profile or a bundled Role Template (matched by \
        name) against what's actually installed on this Mac. Returns a Desired \
        State report: for each required app, tweak and web app, whether it's \
        compliant, missing, outdated, different, or unknown, plus a list of extra \
        apps present but not requested (informational only — never proposed for \
        removal by this tool). Use get_profiles or get_role_templates first to \
        find a valid name. Read-only.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Name of a saved MacSetup profile or a bundled Role Template."),
                ])
            ]),
            "required": .array([.string("name")]),
        ])
    ),
    Tool(
        name: "get_role_templates",
        description: """
        List MacSetup's bundled Role Templates — curated starting selections for a \
        job role or a way people use a Mac — by name, group and summary. Use this \
        to find a valid name for compare_desired_state.
        """,
        inputSchema: emptyObjectSchema(description: "No arguments.")
    ),
    Tool(
        name: "get_profiles",
        description: """
        List the names of the user's saved MacSetup profiles. Use this to find a \
        valid name for compare_desired_state.
        """,
        inputSchema: emptyObjectSchema(description: "No arguments.")
    ),
]

private func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}

@MainActor
private func getDoctorReport() async throws -> CallTool.Result {
    let catalog = try CatalogLoader.load()
    let report = await DoctorEngine.run(catalogApps: catalog.apps)
    let summary = report.results
        .map { "\($0.severity.rawValue.uppercased()): \($0.title) — \($0.details)" }
        .joined(separator: "\n")
    return try CallTool.Result(
        content: [.text(text: summary, annotations: nil, _meta: nil)],
        structuredContent: report, isError: false)
}

@MainActor
private func compareDesiredState(name: String) async throws -> CallTool.Result {
    let catalog = try CatalogLoader.load()
    let profiles = ProfileStore().profiles
    guard let report = await DesiredStateService.compare(name: name, profiles: profiles, catalog: catalog) else {
        return errorResult(
            "No saved profile or Role Template named '\(name)'. "
            + "Call get_profiles or get_role_templates to see valid names.")
    }
    let s = report.summary
    let summary = "\(s.compliant) compliant, \(s.missing) missing, \(s.outdated) outdated, "
        + "\(s.different) different, \(s.unknown) unknown, \(s.extra) extra"
    return try CallTool.Result(
        content: [.text(text: summary, annotations: nil, _meta: nil)],
        structuredContent: report, isError: false)
}

private func getRoleTemplates() throws -> CallTool.Result {
    let catalog = try CatalogLoader.load()
    let templates = catalog.roleTemplateList
    let summary = templates.isEmpty
        ? "No Role Templates are bundled."
        : templates.map { "\($0.name) (\($0.group)) — \($0.summary)" }.joined(separator: "\n")
    return try CallTool.Result(
        content: [.text(text: summary, annotations: nil, _meta: nil)],
        structuredContent: templates, isError: false)
}

@MainActor
private func getProfiles() throws -> CallTool.Result {
    let names = ProfileStore().profiles.map(\.name)
    let summary = names.isEmpty ? "No saved profiles." : names.joined(separator: "\n")
    return try CallTool.Result(
        content: [.text(text: summary, annotations: nil, _meta: nil)],
        structuredContent: names, isError: false)
}

let server = Server(
    name: "macsetup",
    version: "1.0.0",
    instructions: """
    Read-only tools over a Mac's MacSetup catalogue, installed apps, and \
    Desired State comparison. Nothing exposed here installs, updates, \
    changes a system setting, or removes anything.
    """,
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: tools)
}

await server.withMethodHandler(CallTool.self) { params in
    do {
        switch params.name {
        case "get_doctor_report":
            return try await getDoctorReport()
        case "compare_desired_state":
            guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
                return errorResult("Missing required argument: name")
            }
            return try await compareDesiredState(name: name)
        case "get_role_templates":
            return try getRoleTemplates()
        case "get_profiles":
            return try await getProfiles()
        default:
            return errorResult("Unknown tool: \(params.name)")
        }
    } catch {
        return errorResult("Error: \(error.localizedDescription)")
    }
}

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
