import CritterClient
import SwiftUI

/// The home screen. A placeholder for now: the Mac, the connection and the sessions' names.
struct HomeView: View {
    let store: BridgeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.pairing?.macName ?? "")
                .font(.largeTitle.bold())
            Text(SessionText.conn(store.conn))
                .foregroundStyle(.secondary)
            ForEach(store.snapshot?.sessions ?? [], id: \.id) { session in
                Text(session.name)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}
