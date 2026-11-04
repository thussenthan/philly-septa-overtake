import SwiftUI

/// "Do you drive?" and, if so, what the car burns — enough to price a drive.
struct CarFields: View {
    @Binding var hasCar: Bool
    @Binding var car: CarProfile
    /// Saved to the Keychain as it's typed; empty removes it.
    @State private var hereKey = HereKeyStore.key ?? ""

    var body: some View {
        Toggle("I have a car", isOn: $hasCar)
        if hasCar {
            number("City mpg", value: $car.cityMPG, format: .number.precision(.fractionLength(0...1)))
            number("Highway mpg", value: $car.highwayMPG, format: .number.precision(.fractionLength(0...1)))
            number("Gas, per gallon", value: $car.gasPrice, format: .currency(code: "USD"))
            number("Parking", value: $car.parking, format: .currency(code: "USD"))
            // Tolls need a routing service that knows them; without a key, toll
            // routes are left out rather than guessed.
            HStack {
                Text("HERE key")
                SecureField("For tolls (optional)", text: $hereKey)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: hereKey) { _, key in HereKeyStore.save(key) }
            }
            Link("Get a free HERE key", destination: URL(string: "https://platform.here.com/sign-up")!)
                .font(.footnote)
        }
    }

    private func number<F: ParseableFormatStyle>(_ label: String, value: Binding<Double>, format: F) -> some View
    where F.FormatInput == Double, F.FormatOutput == String {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: format)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
        }
    }
}
