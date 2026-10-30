# Free capture presentation verification

Run `npm run test:capture-presentation` on macOS. It uses the existing native lease and external cache/evidence profile; it does not launch Fox, a simulator or a camera.

`apps/ipad/Package.swift` compiles the actual production controller, models and analysis gate. Tests are the existing six `FreeCaptureTests` and six `FreeCaptureAnalysisTests`, not copies. Catalogue identity remains `FoxAppTests/<class>/<method>`; the standalone runner reports the same cases under `FoxCapturePresentationTests`. Original App-host coverage stays in place. No CI trigger or full-acceptance selection changes.

MOD-B adds a seventh controller test for pad-only capture and universal library access (13 standalone cases total). Home, training tools and direct vision routing share the device policy; phone/Duo width changes do not enable development capture. Saved packages, legacy trial reports and sealed diagnostics remain readable/exportable without a native capture backend. Diagnostic reads use `recovering: false`, never draft pruning or implicit sealing. Unsealed drafts remain untouched, rather than being silently recovered by the browser.

Controller dependencies are Foundation and Combine. Camera preview is injected by `CaptureLabView` through a stable `FreeCaptureRuntime`; Bluetooth display data is independent of CoreBluetooth. The runtime forwards controller change notifications so the experiment-mode lock remains responsive. Views still use the iOS rendering SDK; this is state/runtime isolation, not a complete independently packaged UI or a Linux-portable Combine replacement.

Use this lane for page state and options. Rendering, preview lifetime and application wiring still need their affected iOS checks. SDK compilation is not UI or camera execution. Keep the historical iPhone launch failure separate from the later scoped launch recheck.

The A/B review also aligns the formal iPhone test selection with the catalogue: the original lab guidance test and all its assertions remain on iPad, rather than being forced onto a retired phone route. Phone saved-library navigation retains the root menu after rotation, so a training user can return to the same session without enabling capture. These are routing fixes, not counting or storage changes. Full acceptance and physical-camera checks remain separate.
