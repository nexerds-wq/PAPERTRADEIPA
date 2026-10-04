import SwiftUI

struct RootView: View {
    var body: some View { NavigationStack { SupplyDemandAutoTraderView() } }
}

struct SupplyDemandAutoTraderView: View {
    var body: some View { ProfessionalAutoTraderView() }
}
