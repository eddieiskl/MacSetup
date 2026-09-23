import Foundation

/// A curated starting selection for a job role or a way people actually use a
/// Mac, bundled with the catalogue so onboarding doesn't start from a blank
/// list of 171 apps.
struct RoleTemplate: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    /// Groups the sidebar list into "Enterprise" and "Consumer" — free text,
    /// not an enum, so a new group needs no code change.
    let group: String
    let symbol: String
    let summary: String
    let appIDs: [String]
    let tweakIDs: [String]
    let webAppIDs: [String]

    /// Applying a template is identical to applying a saved profile — same
    /// intersection-with-what-exists safety, same UI — so it borrows the type
    /// rather than duplicating that logic.
    var asProfile: Profile {
        Profile(name: name, appIDs: appIDs, tweakIDs: tweakIDs, webAppIDs: webAppIDs)
    }
}
