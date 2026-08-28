import SwiftUI

// MARK: - Voice recording status bar
//
// Replaces InlineVoiceInputView. That view used to swap the whole composer
// text field out for its own read-only transcript display; now the real
// PastableTextView stays mounted at all times (AIChatView.inputFieldOrWaveform)
// and already shows the live transcript (it's the same inputText binding VAD
// segments mirror into). This bar is purely a slim status/controls strip shown
// above the field while voice input is active — it owns no transcript text of
// its own.

struct VoiceRecordingStatusBar: View {
    @ObservedObject var viewModel: VoiceInputViewModel
    var conversationContext: (() -> ConversationContext)?

    private var hasTranscript: Bool {
        !viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            micStateIndicator
            Text(stateLabel)
                .font(.caption)
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
            Spacer()
            if hasTranscript {
                Button {
                    viewModel.clearTranscript()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ChatColors.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel(Text("Clear transcript", comment: "Voice: clear transcript button"))
                VoiceCorrectionButton(viewModel: viewModel, conversationContext: conversationContext)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var micStateIndicator: some View {
        if viewModel.state == .recording {
            InlineMiniWaveform(levels: viewModel.waveformLevels)
                .frame(width: 26, height: 18)
        } else if viewModel.isTranscribing {
            ProgressView().controlSize(.mini)
                .frame(width: 26, height: 18)
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ChatColors.secondaryText)
                .frame(width: 26, height: 18)
        }
    }

    private var stateLabel: String {
        if viewModel.permissionDenied {
            return String(localized: "Microphone access denied — enable it in Settings", comment: "Inline voice permission denied")
        }
        if let err = viewModel.startError {
            return String(localized: "Couldn't start microphone: \(err)", comment: "Inline voice start error")
        }
        switch viewModel.state {
        case .waiting: return String(localized: "Tap to speak", comment: "Inline voice waiting")
        case .recording: return String(localized: "Listening…", comment: "Voice tip: steady recording")
        case .processing: return String(localized: "Recognizing…", comment: "Inline voice processing")
        case .result: return String(localized: "Tap mic to continue", comment: "Voice tip: resume dictation")
        }
    }
}

// MARK: - Manual AI correction button (extracted from InlineVoiceInputView)

/// Standing "AI correction" button. Tap → run correction on the current transcript;
/// apply the result in place if the model changed anything, otherwise tell the user
/// there was nothing to fix. Writes into `viewModel.transcript` only — AIChatView's
/// `.onChange(of: voiceVM.transcript)` mirrors it into the real composer text.
struct VoiceCorrectionButton: View {
    @ObservedObject var viewModel: VoiceInputViewModel
    var conversationContext: (() -> ConversationContext)?

    @State private var isCorrecting = false
    @State private var showCollectionConsentPrompt = false

    var body: some View {
        Button {
            if !VoiceCorrectionCollectionConsent.shared.hasPrompted {
                showCollectionConsentPrompt = true
            } else {
                runManualCorrection()
            }
        } label: {
            ZStack {
                if isCorrecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ChatColors.secondaryText)
                }
            }
            .frame(width: 24, height: 24)
        }
        .disabled(isCorrecting)
        .accessibilityLabel(Text("Correct transcript with AI", comment: "Voice manual-correction button"))
        .alert(String(localized: "Improve voice corrections?",
                      comment: "One-time prompt: enable correction data collection"),
               isPresented: $showCollectionConsentPrompt) {
            Button(String(localized: "Enable", comment: "Enable correction data collection")) {
                VoiceCorrectionCollectionConsent.shared.isEnabled = true
                VoiceCorrectionCollectionConsent.shared.hasPrompted = true
                runManualCorrection()
            }
            Button(String(localized: "Not Now", comment: "Decline correction data collection"),
                   role: .cancel) {
                VoiceCorrectionCollectionConsent.shared.hasPrompted = true
                runManualCorrection()
            }
        } message: {
            Text("Minis can store your transcript fixes (original → corrected pairs) and accepted AI corrections in a local on-device database to make future voice corrections smarter. Nothing is uploaded. You can change this or clear the data anytime in Settings → Permissions.",
                 comment: "One-time prompt body: correction data collection")
        }
    }

    private func runManualCorrection() {
        let text = viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isCorrecting else { return }
        isCorrecting = true
        VoiceLog.log("[VoiceCorrection] manual correction requested transcript=\"\(text.prefix(40))\" len=\(text.count)")

        let context = conversationContext?() ?? .empty
        Task {
            let suggestion = await VoiceCorrectionEngine.shared.correct(
                transcript: text,
                locale: PhoneticNormalizerRegistry.normalizedLocaleKey(viewModel.language),
                context: context)
            await MainActor.run {
                isCorrecting = false
                guard viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines) == text else {
                    VoiceLog.log("[VoiceCorrection] manual result discarded — transcript changed during run")
                    return
                }
                if suggestion.hasChange {
                    VoiceLog.log("[VoiceCorrection] manual applied: \(suggestion.diffSummary)")
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.setTranscript(suggestion.corrected)
                    }
                    Task.detached(priority: .utility) {
                        await VoiceCorrectionRecorder.shared.recordSuggestionAccepted(
                            original: suggestion.original,
                            corrected: suggestion.corrected,
                            summary: suggestion.diffSummary)
                    }
                } else {
                    let reason = suggestion.rejectedReason ?? "none"
                    VoiceLog.log("[VoiceCorrection] manual: no change (reason=\(reason))")
                    if reason == "llm_timeout" || reason.hasPrefix("llm_error") {
                        MinisToast.show(String(localized: "Correction failed, original kept",
                                               comment: "Voice: AI correction call failed (timeout/error); transcript left unchanged"),
                                        systemImage: "exclamationmark.triangle.fill")
                    } else {
                        MinisToast.show(String(localized: "No corrections needed",
                                               comment: "Voice: AI found nothing to fix"),
                                        systemImage: "sparkles")
                    }
                }
            }
        }
    }
}

// MARK: - Mini waveform (moved from InlineVoiceInputView, made non-private)

struct InlineMiniWaveform: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.suffix(7).enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(ChatColors.secondaryText.opacity(0.85))
                    .frame(width: 3, height: max(5, CGFloat(level) * 18))
                    .animation(.spring(response: 0.18, dampingFraction: 0.6), value: level)
            }
        }
    }
}

// MARK: - Voice recognition language picker (long-press mic menu)

/// Recognition-language picker for the long-press mic config menu. Sourced
/// from VoiceLanguages (SFSpeechRecognizer.supportedLocales, preferred-first),
/// distinct from SpeechRecognitionManager's own SpeechLanguagePickerSheet
/// (AIChatView.swift) which is a different, legacy voice path.
struct VoiceLanguagePickerSheet: View {
    @ObservedObject var viewModel: VoiceInputViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredOptions: [VoiceLanguages.Option] {
        if searchText.isEmpty { return VoiceLanguages.options }
        let query = searchText.lowercased()
        return VoiceLanguages.options.filter {
            $0.label.lowercased().contains(query) || $0.code.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredOptions) { opt in
                Button {
                    viewModel.language = opt.code
                    dismiss()
                } label: {
                    HStack {
                        Text(opt.label).foregroundStyle(.primary)
                        Spacer()
                        if viewModel.language == opt.code {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: Text("Search Languages", comment: "Search field placeholder for speech language picker"))
            .navigationTitle(Text("Voice Language", comment: "Navigation title for speech language picker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done", comment: "Dismiss speech language picker")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
