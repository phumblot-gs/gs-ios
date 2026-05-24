import Foundation

/// A locally-captured upload, surfaced from the capture flow back
/// to the reference detail so the just-taken picture renders
/// immediately even before GS finishes generating its CDN
/// thumbnail URL.
///
/// Without this, returning from the capture flow shows an empty
/// slot (or worse, a broken placeholder) for the latest shot until
/// the user pulls-to-refresh some seconds later — the GS picture
/// row exists but `thumbnail` is still nil while the server-side
/// pipeline runs. Storing the JPEG locally lets us paint pixels
/// during that window; once GS catches up, the rendered fallback
/// is replaced by the real CDN-served thumbnail on the next reload.
struct LocalCapturePreview: Identifiable, Hashable {
    let id = UUID()
    let filename: String
    let jpegData: Data
}
