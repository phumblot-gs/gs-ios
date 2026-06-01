import SwiftUI

extension View {
    /// Presents a small alert with a text field to look up a product by
    /// ref or EAN — used on the scan screens for items whose label /
    /// barcode is missing or unreadable. `onSubmit` receives the typed,
    /// non-empty value.
    func manualLookupAlert(
        isPresented: Binding<Bool>,
        value: Binding<String>,
        onSubmit: @escaping (String) -> Void
    ) -> some View {
        alert("Enter ref or EAN", isPresented: isPresented) {
            TextField("Ref or EAN", text: value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Look up") {
                let typed = value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                value.wrappedValue = ""
                if !typed.isEmpty { onSubmit(typed) }
            }
            Button("Cancel", role: .cancel) { value.wrappedValue = "" }
        } message: {
            Text("Find a product by ref or EAN when its label is missing.")
        }
    }
}
