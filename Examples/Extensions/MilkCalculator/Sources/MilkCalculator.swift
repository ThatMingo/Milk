import Foundation
import SwiftUI
import Combine
import MilkExtensionKit

// Native Milk 0.7 / Extension API 1 workspace panel. No permissions requested.
@MainActor
public final class MilkCalculator: MilkExtension {
    private var model: CalculatorModel?

    public override func activate(context: any ExtensionContext) async throws {
        let calculator = CalculatorModel()
        model = calculator
        try context.contributions.panel(.init(
            id: "calculator",
            title: "Calculator",
            systemImage: "plus.forwardslash.minus",
            minimumSize: CGSize(width: 340, height: 470),
            topbar: true
        ) { _ in
            AnyView(CalculatorScreen(model: calculator))
        })
    }

    public override func deactivate() async {
        model = nil
    }
}

private enum CalcOperator: String {
    case add = "+", subtract = "−", multiply = "×", divide = "÷"

    var mathSymbol: String { rawValue }
}

private struct Calculation: Identifiable {
    let id = UUID()
    let formula: String
    let answer: String
}

@MainActor
private final class CalculatorModel: ObservableObject {
    @Published private(set) var display = "0"
    @Published private(set) var formula = ""
    @Published private(set) var history: [Calculation] = []

    private var numbers: [Double] = []
    private var operations: [CalcOperator] = []
    private var awaitingNumber = false
    private var afterEquals = false

    func clear() {
        display = "0"
        formula = ""
        numbers.removeAll()
        operations.removeAll()
        awaitingNumber = false
        afterEquals = false
    }

    func digit(_ value: String) {
        guard value.count == 1, let ch = value.first, ch.isASCII, ch.isNumber else { return }
        if display == "Error" { clear() }
        if afterEquals { clear() }
        if awaitingNumber {
            display = value
            awaitingNumber = false
        } else if display == "0" {
            display = value
        } else if display == "-0" {
            display = "-" + value
        } else if display.filter({ $0.isNumber }).count < 15 {
            display += value
        }
    }

    func decimal() {
        if display == "Error" { clear() }
        if afterEquals { clear() }
        if awaitingNumber {
            display = "0."
            awaitingNumber = false
        } else if !display.contains(".") {
            display += "."
        }
    }

    func negate() {
        if display == "Error" { return }
        afterEquals = false
        if display.hasPrefix("-") {
            display.removeFirst()
        } else if display != "0" {
            display = "-" + display
        }
    }

    func percent() {
        guard display != "Error", let number = Double(display) else { return }
        afterEquals = false
        setDisplay(number / 100)
        awaitingNumber = false
    }

    func backspace() {
        if display == "Error" { clear(); return }
        if afterEquals { clear(); return }
        if awaitingNumber {
            guard let number = numbers.popLast() else { return }
            if !operations.isEmpty { operations.removeLast() }
            display = format(number)
            awaitingNumber = false
            refreshFormula()
            return
        }
        if !display.isEmpty { display.removeLast() }
        if display.isEmpty || display == "-" { display = "0" }
    }

    func operate(_ operation: CalcOperator) {
        if display == "Error" { return }
        if afterEquals {
            numbers.removeAll()
            operations.removeAll()
            formula = ""
            afterEquals = false
        }
        if awaitingNumber, !operations.isEmpty {
            operations[operations.count - 1] = operation
        } else {
            guard let number = Double(display), number.isFinite else { fail(); return }
            numbers.append(number)
            operations.append(operation)
        }
        awaitingNumber = true
        refreshFormula()
    }

    func equals() {
        guard display != "Error", !operations.isEmpty else { return }
        guard let number = Double(display), number.isFinite else { fail(); return }
        var values = numbers
        values.append(awaitingNumber ? (numbers.last ?? number) : number)
        guard values.count == operations.count + 1 else { fail(); return }

        let expression = expressionText(values, operations) + " ="
        guard let answer = evaluate(values, operations), answer.isFinite else { fail(); return }
        let result = format(answer)
        history.insert(Calculation(formula: expression, answer: result), at: 0)
        if history.count > 24 { history.removeLast() }
        display = result
        formula = expression
        numbers.removeAll()
        operations.removeAll()
        awaitingNumber = false
        afterEquals = true
    }

    func recall(_ item: Calculation) {
        numbers.removeAll()
        operations.removeAll()
        awaitingNumber = false
        afterEquals = true
        display = item.answer
        formula = item.formula
    }

    func clearHistory() { history.removeAll() }

    private func refreshFormula() {
        formula = expressionText(numbers, operations)
    }

    private func expressionText(_ values: [Double], _ operators: [CalcOperator]) -> String {
        var parts: [String] = []
        for i in values.indices {
            parts.append(format(values[i]))
            if i < operators.count { parts.append(operators[i].mathSymbol) }
        }
        return parts.joined(separator: " ")
    }

    private func evaluate(_ initialValues: [Double], _ initialOperators: [CalcOperator]) -> Double? {
        var values = initialValues
        var operators = initialOperators
        var i = 0
        while i < operators.count {
            let op = operators[i]
            if op == .multiply || op == .divide {
                let lhs = values[i]
                let rhs = values[i + 1]
                if op == .divide && rhs == 0 { return nil }
                let value = op == .multiply ? lhs * rhs : lhs / rhs
                guard value.isFinite else { return nil }
                values.replaceSubrange(i...i+1, with: [value])
                operators.remove(at: i)
            } else { i += 1 }
        }
        guard var answer = values.first else { return nil }
        for (index, op) in operators.enumerated() {
            if op == .add { answer += values[index + 1] }
            else if op == .subtract { answer -= values[index + 1] }
            else { return nil }
            if !answer.isFinite { return nil }
        }
        return answer
    }

    private func setDisplay(_ number: Double) {
        guard number.isFinite else { fail(); return }
        display = format(number)
    }

    private func fail() {
        display = "Error"
        formula = "Invalid calculation"
        numbers.removeAll()
        operations.removeAll()
        awaitingNumber = false
        afterEquals = false
    }

    private func format(_ value: Double) -> String {
        if value == 0 { return "0" }
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct CalculatorScreen: View {
    @ObservedObject var model: CalculatorModel
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                calculator
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if geometry.size.width >= 710 {
                    Rectangle().fill(ExtensionTheme.separator).frame(width: 1)
                    history
                        .frame(width: min(260, geometry.size.width * 0.32))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onTapGesture { keyboardFocused = true }
        .onKeyPress { press in
            let key = press.characters
            if key.count == 1, let character = key.first, character.isASCII, character.isNumber {
                model.digit(key)
                return .handled
            }
            switch key {
            case ".", ",": model.decimal()
            case "+": model.operate(.add)
            case "-": model.operate(.subtract)
            case "*", "x", "X": model.operate(.multiply)
            case "/": model.operate(.divide)
            case "%": model.percent()
            case "=", "\r", "\n": model.equals()
            case "\u{7f}", "\u{8}": model.backspace()
            case "\u{1b}": model.clear()
            default: return .ignored
            }
            return .handled
        }
    }

    private var calculator: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ExtensionTheme.accent)
                Text("CALCULATOR")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(1.7)
                    .foregroundStyle(ExtensionTheme.secondaryText)
                Spacer()
                Text("STANDARD")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(ExtensionTheme.secondaryText)
            }
            .padding(.horizontal, 24)
            .padding(.top, 23)

            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 13) {
                Text(model.formula.isEmpty ? " " : model.formula)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(ExtensionTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("Expression")
                Text(model.display)
                    .font(.system(size: 48, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ExtensionTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.40)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Result")
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 24)

            VStack(spacing: 9) {
                row(["AC", "+/−", "%", "÷"])
                row(["7", "8", "9", "×"])
                row(["4", "5", "6", "−"])
                row(["1", "2", "3", "+"])
                HStack(spacing: 9) {
                    keyButton("0").frame(maxWidth: .infinity)
                    keyButton(".").frame(maxWidth: .infinity)
                    keyButton("=").frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            HStack {
                Button { model.backspace() } label: {
                    Label("Delete", systemImage: "delete.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ExtensionTheme.secondaryText)
                .help("Backspace")
                Spacer()
                Text("⌫  Delete  ·  ↵  Equals")
                    .font(.system(size: 10))
                    .foregroundStyle(ExtensionTheme.secondaryText)
            }
            .padding(.horizontal, 25)
            .padding(.bottom, 19)
        }
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ titles: [String]) -> some View {
        HStack(spacing: 9) {
            ForEach(titles, id: \.self) { title in
                keyButton(title).frame(maxWidth: .infinity)
            }
        }
    }

    private func keyButton(_ title: String) -> some View {
        let isEquals = title == "="
        let isOperator = ["÷", "×", "−", "+"].contains(title)
        let isUtility = ["AC", "+/−", "%"].contains(title)
        return Button { execute(title) } label: {
            Text(title)
                .font(.system(size: isUtility ? 16 : 21, weight: isEquals ? .semibold : .medium, design: .rounded))
                .foregroundStyle(isEquals ? Color.white : (isOperator ? ExtensionTheme.accent : ExtensionTheme.text))
                .frame(maxWidth: .infinity)
                .frame(height: 59)
                .background(isEquals ? ExtensionTheme.accent : (isUtility ? ExtensionTheme.hover : ExtensionTheme.surface),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .help(hint(title))
        .accessibilityLabel(hint(title))
    }

    private func execute(_ key: String) {
        switch key {
        case "0"..."9": model.digit(key)
        case ".": model.decimal()
        case "AC": model.clear()
        case "+/−": model.negate()
        case "%": model.percent()
        case "÷": model.operate(.divide)
        case "×": model.operate(.multiply)
        case "−": model.operate(.subtract)
        case "+": model.operate(.add)
        case "=": model.equals()
        default: break
        }
        keyboardFocused = true
    }

    private func hint(_ key: String) -> String {
        switch key {
        case "AC": return "Clear"
        case "+/−": return "Change sign"
        case "%": return "Percent"
        case "÷": return "Divide"
        case "×": return "Multiply"
        case "−": return "Subtract"
        case "+": return "Add"
        case "=": return "Calculate"
        default: return key
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HISTORY")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(ExtensionTheme.secondaryText)
                Spacer()
                if !model.history.isEmpty {
                    Button("Clear") { model.clearHistory() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(ExtensionTheme.secondaryText)
                }
            }
            .padding(19)
            if model.history.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 23, weight: .ultraLight))
                    Text("No calculations yet")
                        .font(.system(size: 12))
                }
                .foregroundStyle(ExtensionTheme.secondaryText)
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.history) { item in
                            Button { model.recall(item) } label: {
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text(item.formula)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(ExtensionTheme.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Text(item.answer)
                                        .font(.system(size: 21, weight: .medium, design: .rounded))
                                        .foregroundStyle(ExtensionTheme.text)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(12)
                                .background(ExtensionTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .help("Recall result")
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 15)
                }
            }
        }
    }
}
