import SwiftUI

struct NotchView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.red)
            Text("Hello Notch")
                .foregroundStyle(.white)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
    }
}

#Preview {
    NotchView()
        .frame(width: 220, height: 32)
        .background(Color.black)
}
