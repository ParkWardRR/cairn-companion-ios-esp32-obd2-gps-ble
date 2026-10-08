#if os(iOS)
import CairnCore
import CarPlay
import UIKit

/// Drives the CarPlay screen.
///
/// The one rule everything else follows from: **the row set is built once and never rebuilt.** Every
/// row is created when the head unit connects and is then only rewritten in place with `setText`,
/// `setDetailText`, `setImage`, and `CPListImageRowItem.update`. `updateSections` is never called in
/// steady state, so a Bluetooth dropout cannot reload the list, collapse a section, or move a row out
/// from under the driver's eye. Readings fade and start showing their age instead of disappearing.
///
/// Updates run on one 1 Hz ticker rather than off BLE notifications. That matches the dongle's own
/// notify rate, bounds how often `setImage` can be called, and — the real reason — means ages keep
/// counting up while *no* data is arriving, which is exactly when the driver needs to see them.
@MainActor
public final class CarPlayHUDCoordinator: NSObject {
    private let interface: CPInterfaceController
    private let glyphs: HUDGlyphRenderer
    private let units: HUDUnits

    private let heroSize: CGSize
    private let rowSize: CGSize
    private let tileSize: CGSize
    private let tileLimit: Int

    private var ticker: Task<Void, Never>?
    private var decks: [Deck] = []
    private var strip: CPListImageRowItem?
    private var stripSectionIndex = 1
    private var previous: HUDSnapshot?
    private var sessionConfiguration: CPSessionConfiguration?

    /// The tiles the engine strip shows. Frozen for the whole CarPlay session, and remembered across
    /// launches, so a naturally-aspirated car never grows a boost tile and no tile ever moves.
    private var slots: [HUDGauge.Kind]
    private var slotsCameFromLiveData: Bool
    private static let slotsKey = "cairn.carplay.gaugeSlots"

    /// Glyphs are drawn at @2x, which is the scale Apple asks CarPlay assets for. A driving-task app
    /// has no window on the car screen — `CPTemplateApplicationScene.carWindow` belongs to navigation
    /// apps — so there is nothing to ask for the real scale.
    public static let carPlayScale: CGFloat = 2

    public init(
        interface: CPInterfaceController, units: HUDUnits,
        screenScale: CGFloat = CarPlayHUDCoordinator.carPlayScale
    ) {
        self.interface = interface
        self.units = units
        glyphs = HUDGlyphRenderer(scale: screenScale)

        let listImage = CPListItem.maximumImageSize
        heroSize = Self.square(listImage, ceiling: 64)
        rowSize = Self.square(listImage, ceiling: 46)
        tileSize = CPListImageRowItem.maximumImageSize
        tileLimit = max(1, min(CPMaximumNumberOfGridImages, 5))

        let remembered = (UserDefaults.standard.array(forKey: Self.slotsKey) as? [String])?
            .compactMap(HUDGauge.Kind.init(rawValue:)) ?? []
        slots = remembered.isEmpty
            ? HUDBuilder.gaugeSlots(for: nil, limit: tileLimit)
            : Array(remembered.prefix(tileLimit))
        slotsCameFromLiveData = !remembered.isEmpty
        super.init()
    }

    private static func square(_ size: CGSize, ceiling: CGFloat) -> CGSize {
        let side = max(24, min(min(size.width, size.height), ceiling))
        return CGSize(width: side, height: side)
    }

    // MARK: - Lifecycle

    public func start() {
        decks = [buildNow(), buildTrip(), buildDevice()]
        // Paint real values before the root template is shown, so the first thing the driver sees is
        // the dongle's actual state and not an empty frame.
        refresh(now: Date())
        let tabBar = CPTabBarTemplate(templates: decks.map(\.template))
        interface.setRootTemplate(tabBar, animated: false, completion: nil)
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        log("connected · \(decks.count) decks · \(slots.map(\.rawValue).joined(separator: ",")) · tiles \(Int(tileSize.width))x\(Int(tileSize.height))")
        startTicker()
    }

    /// The head unit went away. Stop doing work for a screen nobody is looking at, and drop the
    /// template references — but touch nothing that is recording.
    public func stop() {
        ticker?.cancel()
        ticker = nil
        sessionConfiguration = nil
        decks.removeAll()
        strip = nil
        previous = nil
        log("disconnected")
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refresh(now: Date())
            }
        }
    }

    // MARK: - Building the fixed skeleton

    private final class Deck {
        let template: CPListTemplate
        let hero: CPListItem
        let rows: [HUDRowID: CPListItem]

        init(template: CPListTemplate, hero: CPListItem, rows: [HUDRowID: CPListItem]) {
            self.template = template
            self.hero = hero
            self.rows = rows
        }
    }

    private func blank() -> CPListItem { CPListItem(text: " ", detailText: nil) }

    private func buildNow() -> Deck {
        let hero = blank()
        let acceptance = blank()
        let phoneFix = blank()
        // Static labels under each tile. The *values* are drawn inside the glyphs, which is the one
        // surface CarPlay lets Cairn rewrite freely — so no caption depends on a label update landing.
        let strip = CPListImageRowItem(
            text: "Engine",
            images: slots.map { _ in UIImage() },
            imageTitles: slots.map(\.label)
        )
        self.strip = strip

        let template = CPListTemplate(title: "Cairn", sections: [
            CPListSection(items: [hero]),
            CPListSection(items: [strip], header: "Live engine", sectionIndexTitle: nil),
            CPListSection(items: [acceptance, phoneFix], header: "Phone link", sectionIndexTitle: nil),
        ])
        template.tabTitle = "Now"
        template.tabImage = UIImage(systemName: "speedometer")
        return Deck(template: template, hero: hero, rows: [.acceptance: acceptance, .phoneFix: phoneFix])
    }

    private func buildTrip() -> Deck {
        let hero = blank()
        let rows: [HUDRowID: CPListItem] = [
            .accepted: blank(), .rejected: blank(), .queueDrops: blank(), .drops: blank(),
        ]
        let order: [HUDRowID] = [.accepted, .rejected, .queueDrops, .drops]
        let template = CPListTemplate(title: "Trip", sections: [
            CPListSection(items: [hero]),
            CPListSection(items: order.map { rows[$0]! }, header: "This trip", sectionIndexTitle: nil),
        ])
        template.tabTitle = "Trip"
        template.tabImage = UIImage(systemName: "checklist")
        return Deck(template: template, hero: hero, rows: rows)
    }

    private func buildDevice() -> Deck {
        let hero = blank()
        let rows: [HUDRowID: CPListItem] = [
            .battery: blank(), .storage: blank(), .firmware: blank(), .bond: blank(),
        ]
        let order: [HUDRowID] = [.battery, .storage, .firmware, .bond]
        let template = CPListTemplate(title: "Device", sections: [
            CPListSection(items: [hero]),
            CPListSection(items: order.map { rows[$0]! }, header: "Dongle", sectionIndexTitle: nil),
        ])
        template.tabTitle = "Device"
        template.tabImage = UIImage(systemName: "memorychip")
        return Deck(template: template, hero: hero, rows: rows)
    }

    // MARK: - Refresh

    private func refresh(now: Date) {
        let input = currentInput(now: now)
        freezeSlotsIfNeeded(input)
        let snapshot = HUDBuilder.snapshot(input, now: now, slots: slots)
        apply(snapshot)
        previous = snapshot
    }

    private func currentInput(now: Date) -> HUDInput {
        guard let state = CairnCarPlayLink.shared.state else {
            // Only reachable if CarPlay connects before launch finishes wiring the session up.
            return HUDInput(
                link: .waiting, stage: "Starting Cairn",
                linkDetail: "Cairn is still waking up.", units: units, gaugeSlots: slots.count
            )
        }
        return HUDInput(
            state: state, deviceInfo: CairnCarPlayLink.shared.currentDeviceInfo(),
            units: units, gaugeSlots: slots.count, now: now
        )
    }

    /// The strip's tile set is chosen from what this car actually answers, and remembered, so the
    /// right tiles are up from the first second of the next drive.
    ///
    /// The one and only time the list is allowed to reload is here: if Cairn has never seen a live OBD
    /// snapshot before and the car turns out to answer a different set of PIDs than the default guess.
    /// That happens within a second or two of the first ever connection and never again.
    private func freezeSlotsIfNeeded(_ input: HUDInput) {
        guard !slotsCameFromLiveData, let obd = input.obd else { return }
        slotsCameFromLiveData = true
        let preferred = HUDBuilder.gaugeSlots(for: obd, limit: tileLimit)
        UserDefaults.standard.set(preferred.map(\.rawValue), forKey: Self.slotsKey)
        guard preferred != slots else { return }
        slots = preferred
        rebuildStrip()
    }

    private func rebuildStrip() {
        guard let deck = decks.first else { return }
        let replacement = CPListImageRowItem(
            text: "Engine",
            images: slots.map { _ in UIImage() },
            imageTitles: slots.map(\.label)
        )
        strip = replacement
        var sections = deck.template.sections
        guard sections.indices.contains(stripSectionIndex) else { return }
        sections[stripSectionIndex] = CPListSection(
            items: [replacement], header: "Live engine", sectionIndexTitle: nil
        )
        deck.template.updateSections(sections)
        // Force the tiles to redraw: the comparison below has no previous strip to diff against.
        previous = nil
        log("strip now \(slots.map(\.rawValue).joined(separator: ","))")
    }

    private func apply(_ snapshot: HUDSnapshot) {
        guard decks.count == 3 else { return }
        apply(snapshot.now, to: decks[0], previous: previous?.now, hasStrip: true)
        apply(snapshot.drive, to: decks[1], previous: previous?.drive, hasStrip: false)
        apply(snapshot.device, to: decks[2], previous: previous?.device, hasStrip: false)
    }

    private func apply(_ deck: HUDDeck, to view: Deck, previous: HUDDeck?, hasStrip: Bool) {
        let hero = deck.hero
        if hero.headline != previous?.hero.headline { view.hero.setText(hero.headline) }
        if hero.detail != previous?.hero.detail { view.hero.setDetailText(hero.detail) }
        if let old = previous?.hero {
            if old.stones != hero.stones || old.band != hero.band || old.freshness != hero.freshness {
                view.hero.setImage(glyphs.keystone(hero, size: heroSize))
            }
        } else {
            view.hero.setImage(glyphs.keystone(hero, size: heroSize))
        }

        for row in deck.rows {
            guard let item = view.rows[row.id] else { continue }
            let old = previous?.rows.first { $0.id == row.id }
            if row.title != old?.title { item.setText(row.title) }
            if row.detail != old?.detail { item.setDetailText(row.detail) }
            if old == nil || row.imageKey != old?.imageKey {
                item.setImage(glyphs.meter(row, size: rowSize))
            }
        }

        guard hasStrip, let strip else { return }
        let fingerprint = deck.gauges.map { [$0.caption, "\($0.imageKey)"] }
        let before = previous?.gauges.map { [$0.caption, "\($0.imageKey)"] }
        guard fingerprint != before else { return }
        strip.update(deck.gauges.map { glyphs.gauge($0, size: tileSize, showsCaption: true) })
    }

    private func log(_ message: String) {
        DriveLog.shared.record("carplay \(message)")
    }
}

// MARK: - Vehicle limits

extension CarPlayHUDCoordinator: CPSessionConfigurationDelegate {
    /// Some vehicles truncate long lists while moving. Cairn's decks are short and the row that
    /// matters is first, so there is nothing to restructure — but it is worth having in the drive log
    /// when a car shows less than expected.
    public nonisolated func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        Task { @MainActor [weak self] in
            self?.log("vehicle limits changed · lists \(limitedUserInterfaces.contains(.lists))")
        }
    }

    public nonisolated func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        contentStyleChanged contentStyle: CPContentStyle
    ) {
        Task { @MainActor [weak self] in
            self?.log("content style \(contentStyle.contains(.dark) ? "dark" : "light")")
        }
    }
}
#endif
