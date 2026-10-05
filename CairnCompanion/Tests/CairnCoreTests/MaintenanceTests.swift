import CairnCore
import Foundation
import Testing

@Suite("MaintenanceEntry")
struct MaintenanceEntryTests {
    @Test func defaultID() {
        let e = MaintenanceEntry(vehicleID: "v1", category: .oilChange, performedAt: Date(), title: "Oil Change")
        #expect(!e.id.isEmpty)
    }

    @Test func codableRoundTrip() throws {
        let e = MaintenanceEntry(
            vehicleID: "v1",
            category: .brakes,
            performedAt: Date(timeIntervalSince1970: 1700000000),
            title: "Front brake pads",
            notes: "Replaced with Hawk HPS",
            cost: 450.00,
            currencyCode: "USD",
            shop: "Bimmer Werkstatt",
            odometerKm: 87500,
            partNumbers: ["34-11-6-878-876"]
        )
        let data = try JSONEncoder().encode(e)
        let decoded = try JSONDecoder().decode(MaintenanceEntry.self, from: data)
        #expect(decoded == e)
        #expect(decoded.title == "Front brake pads")
        #expect(decoded.partNumbers == ["34-11-6-878-876"])
    }

    @Test func formattedCostUSD() {
        let e = MaintenanceEntry(
            vehicleID: "v1", category: .oilChange, performedAt: Date(),
            title: "Oil Change", cost: 89.99, currencyCode: "USD"
        )
        let formatted = e.formattedCost
        #expect(formatted != nil)
        #expect(formatted!.contains("89.99") || formatted!.contains("89,99"))
    }

    @Test func formattedCostNil() {
        let e = MaintenanceEntry(vehicleID: "v1", category: .oilChange, performedAt: Date(), title: "Oil Change")
        #expect(e.formattedCost == nil)
    }

    @Test func defaultsEmptyPartNumbers() {
        let e = MaintenanceEntry(vehicleID: "v1", category: .tires, performedAt: Date(), title: "Tire rotation")
        #expect(e.partNumbers.isEmpty)
    }

    @Test func hashable() {
        let e1 = MaintenanceEntry(id: "m1", vehicleID: "v1", category: .oilChange, performedAt: Date(), title: "Oil")
        let e2 = MaintenanceEntry(id: "m1", vehicleID: "v1", category: .oilChange, performedAt: Date(), title: "Oil")
        let set: Set<MaintenanceEntry> = [e1, e2]
        #expect(set.count == 1)
    }
}

@Suite("MaintenanceCategory")
struct MaintenanceCategoryTests {
    @Test func allCasesExist() {
        #expect(MaintenanceCategory.allCases.count == 15)
    }

    @Test func displayNames() {
        #expect(MaintenanceCategory.oilChange.displayName == "Oil Change")
        #expect(MaintenanceCategory.sparkPlugs.displayName == "Spark Plugs")
        #expect(MaintenanceCategory.airFilter.displayName == "Air Filter")
    }

    @Test func systemImages() {
        for category in MaintenanceCategory.allCases {
            #expect(!category.systemImage.isEmpty)
        }
    }

    @Test func codableRoundTrip() throws {
        for category in MaintenanceCategory.allCases {
            let data = try JSONEncoder().encode(category)
            let decoded = try JSONDecoder().decode(MaintenanceCategory.self, from: data)
            #expect(decoded == category)
        }
    }
}

@Suite("OdometerCorrection")
struct OdometerCorrectionTests {
    @Test func defaultID() {
        let c = OdometerCorrection(vehicleID: "v1", odometerKm: 50000)
        #expect(!c.id.isEmpty)
    }

    @Test func defaultRevision() {
        let c = OdometerCorrection(vehicleID: "v1", odometerKm: 50000)
        #expect(c.revision == 1)
    }

    @Test func milesConversion() {
        let c = OdometerCorrection(vehicleID: "v1", odometerKm: 100000)
        #expect(c.odometerMiles == 62137)
    }

    @Test func formattedKm() {
        let c = OdometerCorrection(vehicleID: "v1", odometerKm: 87500)
        let formatted = c.formatted(useMiles: false)
        #expect(formatted.contains("km"))
    }

    @Test func formattedMiles() {
        let c = OdometerCorrection(vehicleID: "v1", odometerKm: 87500)
        let formatted = c.formatted(useMiles: true)
        #expect(formatted.contains("mi"))
    }

    @Test func codableRoundTrip() throws {
        let c = OdometerCorrection(vehicleID: "v1", odometerKm: 87500, revision: 2)
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(OdometerCorrection.self, from: data)
        #expect(decoded == c)
    }

    @Test func hashable() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let c1 = OdometerCorrection(id: "o1", vehicleID: "v1", odometerKm: 50000, recordedAt: date)
        let c2 = OdometerCorrection(id: "o1", vehicleID: "v1", odometerKm: 50000, recordedAt: date)
        let set: Set<OdometerCorrection> = [c1, c2]
        #expect(set.count == 1)
    }
}

@Suite("Annotation")
struct AnnotationTests {
    @Test func defaultID() {
        let a = Annotation(targetID: "session-1", text: "Good drive")
        #expect(!a.id.isEmpty)
    }

    @Test func defaultKindIsNote() {
        let a = Annotation(targetID: "session-1", text: "Nice")
        #expect(a.kind == .note)
    }

    @Test func defaultRevision() {
        let a = Annotation(targetID: "session-1", text: "Test")
        #expect(a.revision == 1)
    }

    @Test func defaultEmptyTags() {
        let a = Annotation(targetID: "session-1", text: "Test")
        #expect(a.tags.isEmpty)
    }

    @Test func codableRoundTrip() throws {
        let a = Annotation(
            vehicleID: "v1",
            targetID: "session-1",
            kind: .flag,
            text: "Check this drive",
            tags: ["review", "anomaly"]
        )
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        #expect(decoded == a)
        #expect(decoded.tags == ["review", "anomaly"])
    }

    @Test func hashable() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a1 = Annotation(id: "n1", targetID: "s1", updatedAt: date, text: "Note")
        let a2 = Annotation(id: "n1", targetID: "s1", updatedAt: date, text: "Note")
        let set: Set<Annotation> = [a1, a2]
        #expect(set.count == 1)
    }
}

@Suite("AnnotationKind")
struct AnnotationKindTests {
    @Test func allCases() {
        #expect(AnnotationKind.allCases.count == 3)
    }

    @Test func displayNames() {
        #expect(AnnotationKind.note.displayName == "Note")
        #expect(AnnotationKind.flag.displayName == "Flag")
        #expect(AnnotationKind.favorite.displayName == "Favorite")
    }

    @Test func systemImages() {
        for kind in AnnotationKind.allCases {
            #expect(!kind.systemImage.isEmpty)
        }
    }
}
