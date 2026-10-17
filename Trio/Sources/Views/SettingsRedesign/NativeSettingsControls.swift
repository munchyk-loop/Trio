import SwiftUI

struct SettingsHelpFooter: View {
    let title: String
    let text: String
    var detail: String? = nil
    @State private var showingHelp = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(LocalizedStringKey(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button { showingHelp = true } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("More information about \(title)"))
        }
        .sheet(isPresented: $showingHelp) {
            NavigationStack {
                ScrollView {
                    Text(LocalizedStringKey(detail ?? text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(LocalizedStringKey(title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { showingHelp = false } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
    }
}

struct SettingsNumberRow: View {
    let title: String
    @Binding var value: Decimal
    var spec: PickerSetting
    var units: GlucoseUnits = .mgdL
    var suffix: String? = nil
    var includeOff = false
    var displayTransform: (Decimal) -> Decimal = { $0 }

    private var values: [Decimal] {
        var values = PickerSettingsProvider.shared.generatePickerValues(from: spec, units: units)
        if includeOff, !values.contains(0) { values.insert(0, at: 0) }
        if !values.contains(value) { values.append(value)
            values.sort() }
        return values
    }

    private func formatted(_ value: Decimal) -> String {
        if includeOff, value == 0 { return String(localized: "Off") }
        let displayed = displayTransform(value)
        let number: Decimal
        let unit: String
        if let suffix {
            number = displayed
            unit = suffix
        } else {
            switch spec.type {
            case .factor: number = displayed * 100
                unit = "%"
            case .glucose: number = units == .mmolL ? displayed.asMmolL : displayed
                unit = units.rawValue
            case .insulinUnit: number = displayed
                unit = "U"
            case .insulinUnitPerHour: number = displayed
                unit = "U/hr"
            case .gram: number = displayed
                unit = "g"
            case .minute: number = displayed
                unit = "min"
            case .hour: number = displayed
                unit = "hr"
            }
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = spec.type == .glucose && units == .mmolL ? 1 : 3
        return "\(formatter.string(from: number as NSDecimalNumber) ?? number.description) \(unit)"
    }

    var body: some View {
        NavigationLink {
            Form {
                Picker(LocalizedStringKey(title), selection: $value) {
                    ForEach(values, id: \.self) { value in
                        Text(formatted(value)).tag(value)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .navigationTitle(LocalizedStringKey(title))
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent(LocalizedStringKey(title)) { Text(formatted(value)) }
        }
    }
}

struct SettingsPlaceholderLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary)
                .frame(width: 29, height: 29)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
        }
    }
}
