# Phase 3 delivery

This archive includes the existing backend and the updated iOS app with photo capture, review, processing states, CoreML execution scaffolding and an explicitly labeled Debug-only example result flow.

- [Phase 3 behavior and verification](berkeley-plate-ios/PHASE3.md)
- [Mac/iPhone setup](berkeley-plate-ios/README.md)
- [CoreML diagnostic conversion commands](berkeley-plate-ios/MODEL_INTEGRATION.md)
- [Backend setup](berkeley-dining-backend/README.md)

All 20 Swift files passed syntax parsing. The 18 iOS test methods, Xcode builds, hardware capture and CoreML conversion/inference are still unexecuted here because the authoring machine is Windows. No real food analysis or portion accuracy is claimed. Production analysis correctly reports missing models, and ordinary photo capture is never treated as metric depth.

No image upload or meal logging endpoint was added. Earlier phase archives are preserved.
