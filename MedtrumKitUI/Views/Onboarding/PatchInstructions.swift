import LoopKitUI
import SwiftUI

/// One illustrated step of preparing, applying or removing a patch.
struct PatchInstructionStep: Identifiable {
    enum Note {
        case info(String)
        case warning(String)
    }

    let id: Int
    let title: String
    let section: String
    let assetName: String
    let body: String
    let notes: [Note]
}

/// The walkthroughs, in the order the patch is handled: fill and prime it
/// while it is off the body, then attach it and insert the needle, and at the
/// end of its life, remove it. They follow Medtrum's Nano quick start guide.
enum PatchInstructionSteps {
    private struct Draft {
        let section: String
        let assetName: String
        let body: String
        var notes: [PatchInstructionStep.Note] = []
    }

    private static func numbered(_ drafts: [Draft]) -> [PatchInstructionStep] {
        drafts.enumerated().map { index, draft in
            PatchInstructionStep(
                id: index + 1,
                title: String(
                    format: String(
                        localized: "Step %1$d of %2$d",
                        comment: "Patch walkthrough step counter (1: step number, 2: step count)"
                    ),
                    index + 1,
                    drafts.count
                ),
                section: draft.section,
                assetName: draft.assetName,
                body: draft.body,
                notes: draft.notes
            )
        }
    }

    static let minimumFillNote = PatchInstructionStep.Note.warning(String(
        localized: "At least 70 U is required to activate the patch.",
        comment: "Prime step 4 note: minimum fill"
    ))

    static let notOnBodyNote = PatchInstructionStep.Note.warning(String(
        localized: "Do not attach the patch to your body yet.",
        comment: "Prime step 5 note: not on the body yet"
    ))

    static var priming: [PatchInstructionStep] {
        let connect = String(localized: "CONNECT PUMP BASE", comment: "Section label above the connect-pump-base step")
        let syringe = String(localized: "PREPARE SYRINGE", comment: "Section label above the prepare-syringe steps")
        let air = String(localized: "REMOVE AIR", comment: "Section label above the remove-air steps")
        let fill = String(localized: "FILL PATCH", comment: "Section label above the fill-patch steps")
        let prime = String(localized: "PRIME PATCH", comment: "Section label above the prime-patch step")

        return numbered([
            Draft(
                section: connect,
                assetName: "step_connect_base",
                body: String(
                    localized: "Insert the pump base straight down into a new patch and push it all the way until it clicks into place.",
                    comment: "Prime step: connect the pump base"
                ),
                notes: [.info(String(
                    localized: "The pump beeps 4 times. Check that the serial number on the pump base matches the one in the pump base settings.",
                    comment: "Prime step note: beeps and serial number"
                ))]
            ),
            Draft(
                section: syringe,
                assetName: "step_vial_air",
                body: String(localized: "Push air into the insulin vial.", comment: "Prime step: push air into the vial")
            ),
            Draft(
                section: syringe,
                assetName: "step_fill_syringe",
                body: String(localized: "Fill the syringe with insulin.", comment: "Prime step 2: fill the syringe"),
                notes: [.info(String(
                    localized: "Decide on the amount of insulin together with your healthcare provider.",
                    comment: "Prime step note: amount of insulin"
                ))]
            ),
            Draft(
                section: air,
                assetName: "step_remove_air",
                body: String(
                    localized: "Insert the needle straight into the fill port. Gently pull the plunger back to draw one to two air bubbles into the syringe.",
                    comment: "Prime step: draw air out of the patch"
                )
            ),
            Draft(
                section: air,
                assetName: "step_tap_bubbles",
                body: String(
                    localized: "Remove the needle from the fill port. Hold the syringe upright, tap it to move the air bubbles to the top, and push the plunger until a drop of insulin appears at the tip.",
                    comment: "Prime step: clear the air from the syringe"
                )
            ),
            Draft(
                section: fill,
                assetName: "step_fill_patch",
                body: String(
                    localized: "Insert the needle straight into the fill port again and slowly fill the patch with insulin.",
                    comment: "Prime step: fill the patch"
                ),
                notes: [
                    minimumFillNote,
                    .warning(String(
                        localized: "Do not inject air into the fill port. It may cause unintended or interrupted insulin delivery.",
                        comment: "Prime step note: no air into the fill port"
                    ))
                ]
            ),
            Draft(
                section: prime,
                assetName: "step_prime",
                body: String(
                    localized: "With the safety lock still on, press the needle button, then tap \"Start priming\".",
                    comment: "Prime step: press the needle button and start priming"
                ),
                notes: [
                    notOnBodyNote,
                    .info(String(
                        localized: "Priming takes about 3 minutes. Keep your phone within about 30 cm (1 ft) of the pump.",
                        comment: "Prime step note: duration and distance"
                    ))
                ]
            )
        ])
    }

    static var activation: [PatchInstructionStep] {
        let site = String(localized: "PREPARE SITE", comment: "Section label above the prepare-site step")
        let apply = String(localized: "APPLY PATCH", comment: "Section label above the apply-patch steps")
        let insert = String(localized: "INSERT NEEDLE", comment: "Section label above the insert-needle step")

        return numbered([
            Draft(
                section: site,
                assetName: "step_infusion_site",
                body: String(
                    localized: "Choose a site on your abdomen, hips, lower back, upper arms or thighs. Wash your hands, clean the site with an alcohol wipe and let it dry completely.",
                    comment: "Activation step: choose and clean a site"
                ),
                notes: [
                    .info(String(
                        localized: "Pick a site with enough fat, at least 2.5 cm (1 inch) from the last one and away from your navel.",
                        comment: "Activation step note: site selection"
                    )),
                    .info(String(
                        localized: "On the abdomen, back or buttocks, apply the patch horizontally. On the upper arm or thigh, apply it vertically.",
                        comment: "Activation step note: patch orientation"
                    ))
                ]
            ),
            Draft(
                section: apply,
                assetName: "step_remove_safety_lock",
                body: String(
                    localized: "Slide the safety lock off horizontally.",
                    comment: "Activation step: remove the safety lock"
                )
            ),
            Draft(
                section: apply,
                assetName: "step_peel_liner",
                body: String(localized: "Peel off the adhesive liners.", comment: "Activation step: peel off the liners")
            ),
            Draft(
                section: apply,
                assetName: "step_attach_patch",
                body: String(localized: "Attach the patch to your skin.", comment: "Activation step: attach the patch")
            ),
            Draft(
                section: apply,
                assetName: "step_press_adhesive",
                body: String(
                    localized: "Run your finger around the entire edge of the adhesive pad and press the patch in place for 5 to 10 seconds.",
                    comment: "Activation step: secure the adhesive"
                )
            ),
            Draft(
                section: insert,
                assetName: "step_insert_needle",
                body: String(
                    localized: "Press the needle button with one quick motion to insert the needle, then tap \"Activate Patch\".",
                    comment: "Activation step: insert the needle and activate"
                )
            )
        ])
    }

    static var removal: [PatchInstructionStep] {
        let remove = String(localized: "REMOVE PATCH", comment: "Section label above the remove-patch steps")

        return numbered([
            Draft(
                section: remove,
                assetName: "step_retract_needle",
                body: String(
                    localized: "After the patch is deactivated, retract the needle with the needle-eject tool.",
                    comment: "Removal step: retract the needle"
                )
            ),
            Draft(
                section: remove,
                assetName: "step_remove_patch",
                body: String(
                    localized: "Gently remove the entire patch from your body.",
                    comment: "Removal step: take the patch off"
                ),
                notes: [
                    .info(String(
                        localized: "Use a medical adhesive remover or baby oil if necessary.",
                        comment: "Removal step note: adhesive remover"
                    )),
                    .warning(String(
                        localized: "Once the patch is off your skin, do not press the needle button again. Doing so will result in injury.",
                        comment: "Removal step note: needle button"
                    ))
                ]
            ),
            Draft(
                section: remove,
                assetName: "step_separate_base",
                body: String(
                    localized: "Fold down and break the tab of the patch, then push the pump base up from the bottom to remove it.",
                    comment: "Removal step: separate the pump base"
                ),
                notes: [
                    .info(String(
                        localized: "Discard the used patch according to your local regulations. Keep the pump base: it is reusable.",
                        comment: "Removal step note: disposal"
                    )),
                    .info(String(
                        localized: "Wait at least 5 seconds before connecting the pump base to a new patch.",
                        comment: "Removal step note: wait before reconnecting"
                    ))
                ]
            )
        ])
    }
}

/// A walkthrough figure. The artwork has an opaque background, so it is shown
/// at its own proportions on a rounded card, which reads well in dark mode too.
/// Callers decide how tall it may be.
struct PatchStepFigure: View {
    let assetName: String

    var body: some View {
        if let image = UIImage(named: assetName, in: Bundle(for: MedtrumKitHUDProvider.self), compatibleWith: nil) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
    }
}

/// The scrolling part of an overview screen: a picture above the text.
///
/// The text (title, warnings, description) is measured first and the picture
/// gets the height that is left, between `minImageHeight` and
/// `maxImageHeight`. On a short phone or with a large text size the picture
/// shrinks so everything still fits without scrolling; only when even the
/// smallest picture leaves too little room does the content scroll, and then
/// what sits right under the picture is the last to go below the fold.
struct PatchOverviewContent<Content: View>: View {
    let assetName: String
    var maxImageHeight: CGFloat = 200
    var minImageHeight: CGFloat = 80
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0

    private let spacing: CGFloat = 20
    private let padding: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    PatchStepFigure(assetName: assetName)
                        .frame(height: imageHeight(available: proxy.size.height))

                    VStack(alignment: .leading, spacing: spacing) {
                        content
                    }
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        contentHeight = height
                    }
                }
                .padding(padding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicatorsFlash(onAppear: true)
        }
    }

    private func imageHeight(available: CGFloat) -> CGFloat {
        let room = available - contentHeight - spacing - 2 * padding
        return min(maxImageHeight, max(minImageHeight, room))
    }
}

/// A note on a step, shown as a tinted callout: orange for things that can go
/// wrong, grey for helpful tips.
struct PatchStepNoteView: View {
    let note: PatchInstructionStep.Note

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .accessibilityLabel(
                    isWarning
                        ? Text("Warning", comment: "Accessibility label of the icon on a warning note in the patch walkthrough")
                        : Text("Note", comment: "Accessibility label of the icon on a tip in the patch walkthrough")
                )

            Text(text)
                .fontWeight(isWarning ? .semibold : .regular)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isWarning ? Color.orange.opacity(0.15) : Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .combine)
    }

    private var isWarning: Bool {
        if case .warning = note {
            return true
        }

        return false
    }

    private var text: String {
        switch note {
        case let .info(text),
             let .warning(text):
            return text
        }
    }

    private var iconName: String {
        isWarning ? "exclamationmark.circle.fill" : "info.circle.fill"
    }

    private var tint: Color {
        isWarning ? .orange : .secondary
    }
}

/// The step-by-step walkthrough, one page per step.
struct PatchStepsPagerView: View {
    let title: String
    let steps: [PatchInstructionStep]
    var didFinish: () -> Void

    @State private var selection: Int

    init(title: String, steps: [PatchInstructionStep], didFinish: @escaping () -> Void) {
        self.title = title
        self.steps = steps
        self.didFinish = didFinish
        _selection = State(initialValue: steps.first?.id ?? 0)
    }

    private var isLastStep: Bool {
        selection == steps.last?.id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    ForEach(steps) { step in
                        PatchStepCard(step: step)
                            .tag(step.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button(action: advance) {
                    Text(
                        isLastStep
                            ? String(localized: "Done", comment: "Button title to close the patch walkthrough")
                            : String(localized: "Next", comment: "Button title to go to the next walkthrough step")
                    )
                    .actionButtonStyle(.primary)
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Button title to close the patch walkthrough"), action: didFinish)
                }
            }
        }
    }

    private func advance() {
        guard let index = steps.firstIndex(where: { $0.id == selection }), index + 1 < steps.count else {
            didFinish()
            return
        }

        withAnimation {
            selection = steps[index + 1].id
        }
    }
}

struct PatchStepCard: View {
    let step: PatchInstructionStep

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PatchStepFigure(assetName: step.assetName)
                    .containerRelativeFrame(.vertical) { length, _ in
                        min(240, length / 3)
                    }
                    .padding(.top, 8)

                Text(step.section)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text(step.title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(step.body)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if !step.notes.isEmpty {
                    PatchKeyPoints(notes: step.notes)
                }
            }
            .padding()
            .padding(.bottom, 40) // room for the page indicator
        }
        .scrollIndicatorsFlash(onAppear: true)
    }
}

/// Key points shown on an overview screen, so the things that matter most
/// are visible without opening the walkthrough.
struct PatchKeyPoints: View {
    let notes: [PatchInstructionStep.Note]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notes.indices, id: \.self) { index in
                PatchStepNoteView(note: notes[index])
            }
        }
    }
}
