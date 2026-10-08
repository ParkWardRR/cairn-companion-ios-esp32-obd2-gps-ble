import CairnRuntime
import CarPlay
import UIKit

/// The CarPlay scene's entry point.
///
/// This lives in the app target rather than in `CairnRuntime` on purpose: UIKit builds it by name from
/// the scene manifest in `Info.plist`, so no Swift code ever references it — and the linker is free to
/// drop a static library's object file that nothing references. Compiled straight into the executable,
/// it cannot go missing.
///
/// It owns nothing but the coordinator. Everything the car screen shows comes from the same
/// `SessionState` the phone screen reads, through `CairnCarPlayLink`.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var hud: CarPlayHUDCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let hud = CarPlayHUDCoordinator(
            interface: interfaceController,
            units: CairnCarPlayLink.units
        )
        self.hud = hud
        hud.start()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        // Release the CarPlay UI only. The dongle link and the logger are untouched: unplugging the
        // phone from the car must not end a trip.
        hud?.stop()
        hud = nil
    }
}
