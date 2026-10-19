# System One Foundation Models trial dependency

This is the Swift source from [peterfriese/system-one-foundation-models](https://github.com/peterfriese/system-one-foundation-models) at commit `c3068589139643cab045c984dd485168103cfbb7` (Apache 2.0). The upstream README refers to release `0.3.0`, but the published tags available when this trial began ended at `0.2.0`; that tag predates Clef. The local package pins the exact source used for the trial and builds the `SystemOneCore`, `LayaFoundationModels`, and `ClefFoundationModels` products.

One source compatibility change was required for the installed macOS 27 SDK: `TranscriptAttachmentExtractor` no longer switches over the removed `Transcript.Entry.data` and `Transcript.Attachment.data` cases. Image attachments remain supported. The unmodified upstream checkout failed to compile with Swift 6.4; the scoped Clef package tests passed after this change.

Laya's trial uses the local `laya-serve` backend and the real `typed-decisions` checkpoint. The on-device Core ML example needs separately converted weights and its default tokenizer is a sample fallback, so that example is not used for the measured trial.
