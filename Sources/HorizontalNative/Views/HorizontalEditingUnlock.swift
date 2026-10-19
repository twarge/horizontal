import SwiftUI

/// Turning read-only off, from Settings or a window's lock: a confirmation
/// that editing is in beta and a risk to the user's data, with the unlock
/// as its destructive choice.
struct HorizontalEditingUnlockConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    @ObservedObject var appearanceSettings: HorizontalAppearanceSettings

    func body(content: Content) -> some View {
        content.alert(HorizontalOperationDefaults.editingUnlockTitle, isPresented: $isPresented) {
            Button("Allow Editing", role: .destructive) {
                appearanceSettings.readOnlyOperationBinding().wrappedValue = false
            }
            Button("Stay Read-Only", role: .cancel) {}
        } message: {
            Text(HorizontalOperationDefaults.editingBetaWarning)
        }
    }
}

extension View {
    func editingUnlockConfirmation(isPresented: Binding<Bool>, appearanceSettings: HorizontalAppearanceSettings) -> some View {
        modifier(HorizontalEditingUnlockConfirmation(isPresented: isPresented, appearanceSettings: appearanceSettings))
    }
}

/// The warning Settings shows in red for as long as editing is allowed.
struct HorizontalEditingBetaWarning: View {
    var body: some View {
        Label {
            Text(HorizontalOperationDefaults.editingBetaWarning)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.5)))
    }
}
