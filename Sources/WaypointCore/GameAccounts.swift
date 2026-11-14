import Foundation

/// Native game licences, distinct from the owning Battle.net identity.
public struct GameAccount: Equatable, Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let title: String
        public let region: String
        public let account: String
    }
    public let titleID: String
    public let accountID: String
    public let name: String
    public let region: String
    public var id: ID { ID(title: titleID, region: region, account: accountID) }
    public init(titleID: String, accountID: String, name: String, region: String) {
        self.titleID = titleID; self.accountID = accountID; self.name = name; self.region = region
    }
}
