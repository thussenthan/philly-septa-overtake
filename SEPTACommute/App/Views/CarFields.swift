import SwiftUI

/// "Do you drive?" and, if so, what the car burns — enough to price a drive.
struct CarFields: View {
    @Binding var hasCar: Bool
    @Binding var car: CarProfile

    var body: some View {
        Toggle("I have a car", isOn: $hasCar)
        if hasCar {
            number("City mpg", value: $car.cityMPG, format: .number.precision(.fractionLength(0...1)))
            number("Highway mpg", value: $car.highwayMPG, format: .number.precision(.fractionLength(0...1)))
            number("Gas, per gallon", value: $car.gasPrice, format: .currency(code: "USD"))
            number("Toll, if any", value: $car.typicalToll, format: .currency(code: "USD"))
            number("Parking", value: $car.parking, format: .currency(code: "USD"))
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
