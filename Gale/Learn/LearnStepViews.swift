import SwiftUI
import GaleLearn

/// The step's title and words.
struct LearnStepHeader: View {
    let step: LearnStep
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.title)
                .font(compact ? .title3.weight(.bold) : .title2.weight(.bold))
                .fontDesign(.rounded)
            if !step.text.isEmpty {
                Text(step.text)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Words to read, often with an animation to watch.
struct LearnReadStepView: View {
    let step: LearnStep

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LearnStepHeader(step: step)
                if let guide = step.guide {
                    LearnGuidePlayer(guide: guide)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
    }
}

/// A question with a few answers to pick from.
struct LearnQuizStepView: View {
    let step: LearnStep
    @Binding var choice: Int?
    let wrongChoices: Set<Int>
    let solved: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !step.title.isEmpty {
                    Text(step.title.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
                if !step.text.isEmpty {
                    Text(step.text).foregroundStyle(.secondary)
                }
                if let guide = step.guide {
                    LearnGuidePlayer(guide: guide)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                }
                if let quiz = step.quiz {
                    Text(quiz.question)
                        .font(.title3.weight(.semibold))
                        .fontDesign(.rounded)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 10) {
                        ForEach(Array(quiz.choices.enumerated()), id: \.offset) { i, text in
                            choiceCard(i, text: text, correct: solved && i == quiz.answer)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private func choiceCard(_ i: Int, text: String, correct: Bool) -> some View {
        let wrong = wrongChoices.contains(i)
        let picked = choice == i
        let border: Color = correct ? .green : (wrong ? .orange : (picked ? Theme.accent : Color.black.opacity(0.1)))
        let letter = String(Character(Unicode.Scalar(UInt8(65 + min(i, 25)))))
        return Button {
            guard !solved, !wrong else { return }
            choice = i
        } label: {
            HStack(spacing: 12) {
                Text(letter)
                    .font(.headline.weight(.bold))
                    .fontDesign(.rounded)
                    .frame(width: 32, height: 32)
                    .background(picked || correct ? border.opacity(0.18) : Color(.secondarySystemFill), in: Circle())
                    .foregroundStyle(picked || correct ? border : Color.secondary)
                Text(text)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if correct {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if wrong {
                    Image(systemName: "xmark.circle").foregroundStyle(.orange)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(border, lineWidth: picked || correct || wrong ? 2 : 1))
            .opacity(wrong ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Answer \(letter): \(text)")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// Learn a tool in Gale's editor: what it does, things to try, and a page to practise on.
struct LearnToolStepView: View {
    let step: LearnStep
    @State private var ticked: Set<Int> = []

    /// Tools you can feel right here on a practice page.
    private var practiceTool: LearnAppTool? {
        guard let tool = step.tool?.tool, tool == .stabilizer || tool == .brush else { return nil }
        return tool
    }

    var body: some View {
        if let tool = practiceTool {
            // The practice page sits outside the scroll view, so drawing never scrolls the page.
            VStack(spacing: 12) {
                ScrollView { info.padding(20) }
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text(tool == .stabilizer ? "Feel the stabilizer" : "Practice page")
                        .font(.headline)
                    LearnPracticePad(showsSmoothing: tool == .stabilizer)
                }
                .frame(maxWidth: 720, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        } else {
            ScrollView { info.padding(20) }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let tool = step.tool?.tool {
                Label(tool.title, systemImage: tool.symbol)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
            LearnStepHeader(step: step)
            if let guide = step.guide {
                LearnGuidePlayer(guide: guide)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
            if let tasks = step.tool?.tasks, !tasks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Try this in the editor after the lesson")
                        .font(.headline)
                    ForEach(Array(tasks.enumerated()), id: \.offset) { i, task in
                        Button {
                            if ticked.contains(i) { ticked.remove(i) } else { ticked.insert(i) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: ticked.contains(i) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(ticked.contains(i) ? Theme.accent : Color.secondary)
                                    .font(.title3)
                                Text(task)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .strikethrough(ticked.contains(i), color: .secondary)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(ticked.contains(i) ? .isSelected : [])
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}
