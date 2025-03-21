import Combine
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

enum MedtrumUIScreen {
    case debugScreen
}

class MedtrumKitUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying,
    UINavigationControllerDelegate
{
    private let colorPalette: LoopUIColorPalette
    private var pumpManager: MedtrumPumpManager?
    private var allowedInsulinTypes: [InsulinType]
    private var allowDebugFeatures: Bool
    
    var screenStack = [MedtrumUIScreen]()
    var currentScreen: MedtrumUIScreen {
        return screenStack.last!
    }

    init(
        pumpManager: MedtrumPumpManager? = nil,
        colorPalette: LoopUIColorPalette,
        pumpManagerSettings: PumpManagerSetupSettings? = nil,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType] = []
    )
    {
        if pumpManager == nil && pumpManagerSettings == nil {
            self.pumpManager = MedtrumPumpManager(state: MedtrumPumpState(rawValue: [:]))
        } else if pumpManager == nil, let pumpManagerSettings = pumpManagerSettings {
            self.pumpManager = MedtrumPumpManager(state: MedtrumPumpState(pumpManagerSettings.basalSchedule))
        } else {
            self.pumpManager = pumpManager
        }
        
        self.colorPalette = colorPalette
        self.allowDebugFeatures = allowDebugFeatures
        self.allowedInsulinTypes = allowedInsulinTypes
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if screenStack.isEmpty {
            screenStack = [getInitialScreen()]
            let viewController = viewControllerForScreen(currentScreen)
            viewController.isModalInPresentation = false
            setViewControllers([viewController], animated: false)
        }
    }
    
    func getInitialScreen() -> MedtrumUIScreen {
        return .debugScreen
    }
    
    private func viewControllerForScreen(_ screen: MedtrumUIScreen) -> UIViewController {
        switch screen {
        case .debugScreen:
            if let pumpManager = self.pumpManager {
                pumpManager.state.isOnboarded = true
                pumpManager.notifyStateDidChange()
                self.pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: pumpManager)
            }
            
            let viewModel = DebugViewModel(self.pumpManager)
            return hostingController(rootView: DebugView(viewModel: viewModel))
        }
    }
    
    private func hostingController<Content: View>(rootView: Content) -> DismissibleHostingController {
        let rootView = rootView
            .environment(\.appName, Bundle.main.bundleDisplayName)
        return DismissibleHostingController(rootView: rootView, colorPalette: colorPalette)
    }

    var pumpManagerOnboardingDelegate: (any LoopKitUI.PumpManagerOnboardingDelegate)?

    var completionDelegate: (any LoopKitUI.CompletionDelegate)?
}
