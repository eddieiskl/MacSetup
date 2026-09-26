import Foundation

/// A curated starting selection for a job role or a way people actually use a
/// Mac, bundled with the catalogue so onboarding doesn't start from a blank
/// list of 171 apps.
public struct RoleTemplate: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// Groups the sidebar list into "Enterprise" and "Consumer" — free text,
    /// not an enum, so a new group needs no code change.
    public let group: String
    public let symbol: String
    public let summary: String
    public let appIDs: [String]
    public let tweakIDs: [String]
    public let webAppIDs: [String]

    /// Applying a template is identical to applying a saved profile — same
    /// intersection-with-what-exists safety, same UI — so it borrows the type
    /// rather than duplicating that logic.
    public var asProfile: Profile {
        Profile(name: name, appIDs: appIDs, tweakIDs: tweakIDs, webAppIDs: webAppIDs)
    }
}
