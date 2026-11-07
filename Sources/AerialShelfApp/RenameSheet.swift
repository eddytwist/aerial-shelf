import SwiftUI

/// A small sheet for renaming a playlist or a video. Unlike an alert's text field,
/// its field is focused at once, so typing goes straight into the name.
struct RenameSheet: View {
    let title: String
    @Binding var name: String
    let rename: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(L.t("Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button(L.t("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Rename"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .defaultFocus($fieldFocused, true)
        // A sheet becomes key only after it has appeared; focus set earlier is lost.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { fieldFocused = true } }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        rename(trimmed)
        dismiss()
    }
}
