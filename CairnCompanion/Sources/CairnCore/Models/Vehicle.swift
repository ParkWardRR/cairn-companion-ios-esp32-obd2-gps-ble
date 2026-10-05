import Foundation

public struct Vehicle: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public var year: Int
    public var make: String
    public var model: String
    public var engineCode: String?
    public var isArchived: Bool

    public init(
        id: String = UUID().uuidString,
        year: Int,
        make: String,
        model: String,
        engineCode: String? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.year = year
        self.make = make
        self.model = model
        self.engineCode = engineCode
        self.isArchived = isArchived
    }

    public var displayName: String {
        var parts = ["\(year)", make, model]
        if let code = engineCode, !code.isEmpty {
            parts.append("— \(code)")
        }
        return parts.joined(separator: " ")
    }
}

public struct VehicleAssignment: Codable, Sendable, Equatable {
    public let dongleID: String
    public let vehicleID: String

    public init(dongleID: String, vehicleID: String) {
        self.dongleID = dongleID
        self.vehicleID = vehicleID
    }
}
