import Combine
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

enum MedtrumUIScreen {
    case welcomeScreen
    case insulinTypeScreen
    case patchSettingsScreen
    case deactivatePatchScreen
    case pumpBaseSettingsScreen
    case patchPrimingScreen
    case patchActivationScreen
    case settingsScreen
    case manualTempBasalScreen
    case patchDetailsScreen
    case patchPreviousDetailsScreen
}

class MedtrumKitUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying,
    UINavigationControllerDelegate
{
    private let colorPalette: LoopUIColorPalette
    private var pumpManager: MedtrumPumpManager?
    private var allowedInsulinTypes: [InsulinType]
    private var allowDebugFeatures: Bool
    private let logger = MedtrumLogger(category: "MedtrumKitUICoordinator")

    deinit {
        logger.info("MedtrumKitUICoordinator deallocated")
    }

    var pumpManagerOnboardingDelegate: (any LoopKitUI.PumpManagerOnboardingDelegate)?
    var completionDelegate: (any LoopKitUI.CompletionDelegate)?

    var screenStack = [MedtrumUIScreen]()
    var currentScreen: MedtrumUIScreen {
        screenStack.last!
    }

    init(
        pumpManager: MedtrumPumpManager? = nil,
        colorPalette: LoopUIColorPalette,
        pumpManagerSettings: PumpManagerSetupSettings? = nil,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType] = []
    )
    {
        if pumpManager == nil, pumpManagerSettings == nil {
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

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true

        if screenStack.isEmpty {
            screenStack = getInitialScreens()

            let viewControllers = screenStack.map {
                let viewController = viewControllerForScreen($0)
                viewController.isModalInPresentation = false
                return viewController
            }

            setViewControllers(viewControllers, animated: false)
        }
    }

    func getInitialScreens() -> [MedtrumUIScreen] {
        guard let pumpManager = self.pumpManager else {
            return [.settingsScreen]
        }

        if !pumpManager.isOnboarded {
            return [.welcomeScreen]
        }

        if pumpManager.state.pumpState.rawValue < PatchState.priming.rawValue {
            return [.settingsScreen, .pumpBaseSettingsScreen]
        }

        if pumpManager.state.pumpState.rawValue < PatchState.primed.rawValue {
            return [.patchPrimingScreen]
        }

        if pumpManager.state.pumpState.rawValue < PatchState.active.rawValue {
            return [.patchActivationScreen]
        }

        return [.settingsScreen]
    }

    private func viewControllerForScreen(_ screen: MedtrumUIScreen) -> UIViewController {
        switch screen {
        case .welcomeScreen:
            return hostingController(
                rootView: OnboardingWelcomeView(nextStep: { [weak self] in self?.navigateTo(.insulinTypeScreen) }),
                title: String(localized: "Welcome", comment: "welcome header")
            )

        case .insulinTypeScreen:
            let nextStep: (InsulinType) -> Void = { [weak self] insulinType in
                guard let self else { return }
                self.pumpManager?.state.insulinType = insulinType
                self.pumpManager?.notifyStateDidChange()

                if let pumpManager = self.pumpManager, pumpManager.isOnboarded {
                    return
                }

                self.navigateTo(.patchSettingsScreen)
            }
            return hostingController(
                rootView: InsulinTypeSelector(
                    initialValue: pumpManager?.state.insulinType ?? allowedInsulinTypes[0],
                    supportedInsulinTypes: allowedInsulinTypes,
                    showSave: pumpManager?.isOnboarded ?? false,
                    didConfirm: nextStep
                ),
                title: String(localized: "Select insulin type", comment: "Title for insulin type")
            )

        case .patchSettingsScreen:
            let nextStep = { [weak self] in
                guard let self else { return }
                if let pumpManager = self.pumpManager, pumpManager.isOnboarded {
                    return
                }

                self.navigateTo(.pumpBaseSettingsScreen)
            }
            let viewModel = PatchSettingsViewModel(
                pumpManager,
                updatePatch: pumpManager?.isOnboarded ?? false,
                nextStep: nextStep
            )

            var dirtyCheck = false
            if let pumpManager = pumpManager {
                dirtyCheck = !pumpManager.state.patchId.isEmpty
            }

            return hostingController(
                rootView: PatchSettingsView(
                    viewModel: viewModel,
                    doDirtyCheck: dirtyCheck
                ),
                title: String(localized: "Patch Settings", comment: "Text for patch settings view")
            )

        case .deactivatePatchScreen:
            let nextStep: () -> Void = { [weak self] in self?.resetNavigationTo([.settingsScreen, .pumpBaseSettingsScreen]) }
            let viewModel = DeactivatePatchViewModel(pumpManager, nextStep)
            return hostingController(
                rootView: PatchDeactivationView(viewModel: viewModel),
                title: String(localized: "Deactivate Patch", comment: "deactive patch")
            )

        case .pumpBaseSettingsScreen:
            let nextStep = { [weak self] in
                guard let self else { return }
                if let pumpManager = self.pumpManager {
                    pumpManager.state.isOnboarded = true
                    pumpManager.notifyStateDidChange()

                    if let pumpManagerOnboardingDelegate = self.pumpManagerOnboardingDelegate {
                        pumpManagerOnboardingDelegate.pumpManagerOnboarding(didCreatePumpManager: pumpManager)
                    } else {
                        self.logger.warning("Not onboarded -> no onboardDelegate...")
                    }
                }

                self.navigateTo(.patchPrimingScreen)
            }

            let viewModel = PumpBaseSettingsViewModel(pumpManager, nextStep)

            return hostingController(
                rootView: PumpBaseSettingsView(viewModel: viewModel),
                title: String(localized: "Pump base settings", comment: "Pump base settings header")
            )

        case .patchPrimingScreen:
            let viewModel = PatchPrimingViewModel(
                pumpManager,
                { [weak self] in self?.resetNavigationTo([.patchActivationScreen]) },
                { [weak self] in self?.navigateTo(.pumpBaseSettingsScreen) },
                { [weak self] in self?.resetNavigationTo([.settingsScreen]) }
            )
            return hostingController(
                rootView: PatchPrimingView(viewModel: viewModel)
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = true },
                title: String(localized: "Patch Priming", comment: "Priming header")
            )

        case .patchActivationScreen:
            let viewModel = PatchActivationViewModel(
                pumpManager,
                { [weak self] in self?.resetNavigationTo([.settingsScreen]) },
                { [weak self] in self?.navigateTo(.patchPrimingScreen) }
            )
            return hostingController(
                rootView: PatchActivationView(viewModel: viewModel)
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = true },
                title: String(localized: "Patch Activation", comment: "Patch activation header")
            )

        case .settingsScreen:
            let toDeactivation: () -> Void = { [weak self] in
                self?.navigateTo(.deactivatePatchScreen)
            }
            let toActivation: (Bool) -> Void = { [weak self] alreadyPrimed in
                self?.navigateTo(alreadyPrimed ? .patchActivationScreen : .patchPrimingScreen)
            }
            let toSettings: () -> Void = { [weak self] in
                self?.navigateTo(.patchSettingsScreen)
            }
            let toTempBasal: () -> Void = { [weak self] in
                self?.navigateTo(.manualTempBasalScreen)
            }
            let toPatchDetails: () -> Void = { [weak self] in
                self?.navigateTo(.patchDetailsScreen)
            }
            let toPreviousPatchDetails: () -> Void = { [weak self] in
                self?.navigateTo(.patchPreviousDetailsScreen)
            }
            let toInsulinType: () -> Void = { [weak self] in
                self?.navigateTo(.insulinTypeScreen)
            }
            let toActivatePatch: () -> Void = { [weak self] in
                self?.navigateTo(.pumpBaseSettingsScreen)
            }

            let viewModel = MedtrumKitSettingsViewModel(
                pumpManager,
                toDeactivation,
                toActivation,
                toSettings,
                toTempBasal,
                toPatchDetails,
                toPreviousPatchDetails,
                toInsulinType,
                { [weak self] in self?.pumpRemoval() },
                toActivatePatch
            )
            return hostingController(
                rootView: MedtrumKitSettings(viewModel: viewModel),
                title: pumpManager?.state.pumpName ?? "Medtrum Nano"
            )

        case .manualTempBasalScreen:
            let viewModel = ManualTempBasalViewModel(
                pumpManager: pumpManager,
                goBack: { [weak self] in
                    guard let self else { return }
                    self.screenStack.removeLast()
                    self.popViewController(animated: true)
                }
            )
            return hostingController(
                rootView: ManualTempBasalView(viewModel: viewModel),
                title: String(localized: "Manual Temp Basal", comment: "header manual temp basal")
            )

        case .patchDetailsScreen:
            let viewModel = PatchDetailsViewModel(pumpManager: pumpManager)
            return hostingController(
                rootView: PatchDetailsView(viewModel: viewModel),
                title: String(localized: "Patch Details", comment: "header patch details")
            )
        case .patchPreviousDetailsScreen:
            let viewModel = PreviousPatchDetailsViewModel(pumpManager: pumpManager)
            return hostingController(
                rootView: PreviousPatchDetailsView(viewModel: viewModel),
                title: String(localized: "Previous Patch Details", comment: "header patch details")
            )
        }
    }

    private func hostingController<Content: View>(
        rootView: Content,
        title: String? = nil,
        largeTitleDisplayMode: UINavigationItem.LargeTitleDisplayMode = .automatic
    ) -> DismissibleHostingController<some View> {
        let rootView = rootView
            .environment(\.appName, Bundle.main.bundleDisplayName)
        let hostedView = DismissibleHostingController(content: rootView, colorPalette: colorPalette)
        hostedView.navigationItem.title = title
        hostedView.navigationItem.largeTitleDisplayMode = largeTitleDisplayMode
        return hostedView
    }

    override func viewDidDisappear(_: Bool) {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func pumpRemoval() {
        pumpManager?.pumpDelegate.notify { delegate in
            delegate?.retractAlert(identifier: MedtrumAlert.patchExpiredNotification(after: .hours(1)).alert.identifier)
        }

        guard let completionDelegate = self.completionDelegate, let pumpManager = self.pumpManager else {
            return
        }

        pumpManager.forgetBluetoothManager()
        pumpManager.notifyDelegateOfDeactivation {
            DispatchQueue.main.async {
                self.pumpManager = nil
                completionDelegate.completionNotifyingDidComplete(self)
            }
        }
    }
}

extension MedtrumKitUICoordinator {
    func navigateTo(_ screen: MedtrumUIScreen) {
        screenStack.append(screen)
        let viewController = viewControllerForScreen(screen)
        viewController.isModalInPresentation = false
        pushViewController(viewController, animated: true)
        viewController.view.layoutSubviews()
    }

    func resetNavigationTo(_ screens: [MedtrumUIScreen]) {
        screenStack = screens
        let viewControllers = screenStack.map {
            let viewController = viewControllerForScreen($0)
            viewController.isModalInPresentation = false
            viewController.view.layoutSubviews()
            return viewController
        }

        setViewControllers(viewControllers, animated: true)
    }
}
