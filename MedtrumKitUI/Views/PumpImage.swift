import SwiftUI

struct PumpBaseSerialFigure: View {
    var height: CGFloat = 150

    var body: some View {
        if let image = UIImage(
            named: "pump_base_serial",
            in: Bundle(for: MedtrumKitHUDProvider.self),
            compatibleWith: nil
        ) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .accessibilityLabel(Text(
                    "Illustration of the pump base, showing the serial number sticker on its back.",
                    comment: "Accessibility label for the pump base serial number illustration"
                ))
        }
    }
}

struct PumpImage: View {
    var is300u: Bool = false
    var height: CGFloat = 150

    init(is300u: Bool = false, height: CGFloat = 150) {
        self.is300u = is300u
        self.height = height
    }

    var body: some View {
        HStack {
            Spacer()
            Image(uiImage: UIImage(
                named: is300u ? "nano300" : "nano200",
                in: Bundle(for: MedtrumKitHUDProvider.self),
                compatibleWith: nil
            )!)
                .resizable()
                .scaledToFit()
                .padding(.horizontal)
                .frame(height: height)
            Spacer()
        }
    }
}
