//
//  ContentView.swift
//  Lumina
//
//  Created by Sebastian Pusch on 05.12.24.
//

import SwiftUI

@MainActor
class LuminaViewModel: ObservableObject {
    @Published var node: LuminaNode?
    @Published var error: Error?
    @Published var hasInteracted: Bool = false  // idk how else to remove the Lumina error after initial start rn
    @Published var isRunning: Bool = false
    @Published var nodeStatus: String = "Not Started"
    @Published var networkType: Network = .mocha
    @Published var events: [NodeEvent] = []
    @Published var connectedPeers: UInt64 = 0
    @Published var trustedPeers: UInt64 = 0
    @Published var syncProgress: Double = 0.0

    private var eventCheckTimer: Timer?
    private var statsTimer: Timer?

    
    nonisolated init() {
        Task { @MainActor in
            await initializeNode()
        }
    }
    
    private func initializeNode() async {
        do {
            node = try LuminaNode(network: networkType)
            isRunning = await node?.isRunning() ?? false
            if hasInteracted {
                await updateStats()
            }
        } catch {
            if hasInteracted {
                self.error = error
            }
        }
    }
    
    func startNode() async {
        hasInteracted = true
        guard let node = node else { return }
        
        do {
            nodeStatus = "Node Initializing"
            let started = try await node.start()
            
            if started {
                isRunning = true
                nodeStatus = "Running"
                startEventChecking()
                startStatsUpdates()
                await updateStats()
            }
            
            isRunning = await node.isRunning()
        } catch {
            self.error = error
        }
    }
    
    func stopNode() async {
        do {
            try await node?.stop()
            isRunning = false
            nodeStatus = "Stopped"
            stopEventChecking()
            stopStatsUpdates()
            connectedPeers = 0
            trustedPeers = 0
            syncProgress = 0.0
        } catch {
            self.error = error
        }
    }
        
        
    private func startStatsUpdates() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.updateStats()
            }
        }
        Task { @MainActor in
            await updateStats()
        }
    }
    
    private func stopStatsUpdates() {
        statsTimer?.invalidate()
        statsTimer = nil
    }
    
    private let approxHeadersToSync: Double = (30.0 * 24.0 * 60.0 * 60.0) / 12.0 // 30 days with ~12s block time, similiar to luminas web impl.
    
    private func updateStats() async {
       guard let node = node else { return }
       
       do {
           let peerInfo = try await node.peerTrackerInfo()
           connectedPeers = peerInfo.numConnectedPeers
           trustedPeers = peerInfo.numConnectedTrustedPeers
           
           if let syncInfo = try? await node.syncerInfo() {
               let syncWindowTail = Int64(syncInfo.subjectiveHead) - Int64(approxHeadersToSync)

               var totalSyncedBlocks: Double = 0
               for range in syncInfo.storedHeaders {
                   let adjustedStart = max(Double(range.start), Double(syncWindowTail))
                   let adjustedEnd = max(Double(range.end), Double(syncWindowTail))
                   totalSyncedBlocks += adjustedEnd - adjustedStart
               }
               
               syncProgress = (totalSyncedBlocks * 100.0) / approxHeadersToSync
               
               if syncProgress >= 100 {
                   nodeStatus = "Fully synced"
               } else if syncProgress > 0 {
                   nodeStatus = "Syncing: \(Int(syncProgress))%"
               } else {
                   nodeStatus = "Starting sync..."
               }
           }
           
           error = nil
       } catch {
           if hasInteracted {
               self.error = error
           }
       }
   }
    
    private func startEventChecking() {
        eventCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkForEvents()
            }
        }
    }
    
    private func stopEventChecking() {
        eventCheckTimer?.invalidate()
        eventCheckTimer = nil
    }
        
    private func checkForEvents() async {
        guard let node = node else { return }
        
        do {
            while let event = try await node.eventsChannel() {
                handleEvent(event)
            }
        } catch {
            self.error = error
        }
    }
    
    private func handleEvent(_ event: NodeEvent) {
        switch event {
        case .connectingToBootnodes:
            self.nodeStatus = "Connecting to bootnodes..."
            
        case .peerConnected(let id, let trusted):
            self.nodeStatus = "Connected to peer: \(id.peerId) (trusted: \(trusted))"
            
        case .peerDisconnected(let id, _):
            self.nodeStatus = "Peer disconnected: \(id.peerId)"
            
        case .samplingStarted(let height, _, _):
            self.nodeStatus = "Sampling data at height \(height)"
            
        case .samplingFinished(let height, let accepted, _):
            self.nodeStatus = "Sampling finished at height \(height) (accepted: \(accepted))"
            
        case .fetchingHeadersStarted(let from, let to):
            self.nodeStatus = "Fetching headers \(from) to \(to)"
            
        case .fetchingHeadersFinished(let from, let to, _):
            self.nodeStatus = "Headers synced \(from) to \(to)"
            
        case .fetchingHeadersFailed(_, _, let error, _):
            self.nodeStatus = "Sync failed: \(error)"
            
        default:
            print("Event received: \(event)")
            break
        }
        
        // Keep last 100 events to display
        self.events.append(event)
        if self.events.count > 100 {
            self.events = Array(self.events.suffix(100))
        }
    }
    
    func changeNetwork(_ network: Network) async {
        await stopNode()
        networkType = network
        await initializeNode()
    }
    
    deinit {
        eventCheckTimer?.invalidate()
        statsTimer?.invalidate()
    }
    
    func refreshRunningState() async {
        isRunning = await node?.isRunning() ?? false
    }
}

struct ContentView: View {
    @StateObject private var viewModel = LuminaViewModel()
    @State private var showingNetworkSelection = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello Lumina!")
                .font(.title)
            
            if let error = viewModel.error {
                Text("Error: \(error.localizedDescription)")
                    .foregroundColor(.red)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
            }
            
            if !viewModel.isRunning {
                Button("Start Node") {
                    showingNetworkSelection = true
                }
                .buttonStyle(.borderedProminent)
                .sheet(isPresented: $showingNetworkSelection) {
                    NetworkSelectionView(viewModel: viewModel, isPresented: $showingNetworkSelection)
                }
               } else {
                   VStack(spacing: 15) {
                       StatusCard(
                           status: viewModel.nodeStatus,
                           isRunning: viewModel.isRunning,
                           connectedPeers: viewModel.connectedPeers,
                           trustedPeers: viewModel.trustedPeers,
                           syncProgress: viewModel.syncProgress
                       )
                       
                       EventsView(events: viewModel.events)
                       
                       HStack(spacing: 20) {
                           Button("Stop") {
                               Task {
                                   await viewModel.stopNode()
                               }
                           }
                           .buttonStyle(.bordered)
                           
                           Button("Restart") {
                               Task {
                                   await viewModel.stopNode()
                                   await viewModel.startNode()
                               }
                           }
                           .buttonStyle(.bordered)
                       }
                   }
               }
           }
           .padding()
           .task {
               await viewModel.refreshRunningState()
           }
       }
}

struct StatusCard: View {
    let status: String
    let isRunning: Bool
    let connectedPeers: UInt64
    let trustedPeers: UInt64
    let syncProgress: Double
    
    var body: some View {
       VStack(spacing: 12) {
           HStack {
               Text("Node Status")
                   .font(.headline)
               Spacer()
               Text(isRunning ? "Running" : "Stopped")
                   .foregroundColor(isRunning ? .green : .red)
                   .fontWeight(.medium)
           }
           
           Divider()
           
           if isRunning {
                  VStack(spacing: 8) {
                      // a cute Progress bar
                      GeometryReader { geometry in
                          ZStack(alignment: .leading) {
                              Rectangle()
                                  .fill(Color(.systemGray5))
                                  .frame(width: geometry.size.width, height: 8)
                                  .cornerRadius(4)
                              
                              Rectangle()
                                  .fill(Color.blue)
                                  .frame(width: min(CGFloat(syncProgress) / 100.0 * geometry.size.width, geometry.size.width), height: 8)
                                  .cornerRadius(4)
                          }
                      }
                      .frame(height: 8)
                    
                      HStack {
                          Text("Sync Progress")
                              .foregroundColor(.secondary)
                          Spacer()
                          Text(String(format: "%.1f%%", min(syncProgress, 100)))
                              .fontWeight(.medium)
                      }
                      
                      Divider()
                      
                      HStack {
                          Text("Connected Peers")
                              .foregroundColor(.secondary)
                          Spacer()
                          Text("\(connectedPeers)")
                              .fontWeight(.medium)
                      }
                      
                      HStack {
                          Text("Trusted Peers")
                              .foregroundColor(.secondary)
                          Spacer()
                          Text("\(trustedPeers)")
                              .fontWeight(.medium)
                      }
                  }
              }
          }
           .padding()
           .background(Color(.systemGray6))
           .cornerRadius(10)
    }
}

struct StatRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

struct NetworkSelectionView: View {
    @ObservedObject var viewModel: LuminaViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            List {
                ForEach([Network.mainnet, .arabica, .mocha, .custom(NetworkId(id: "private"))], id: \.self) { network in
                    Button {
                        Task {
                            await viewModel.changeNetwork(network)
                            await viewModel.startNode()
                            isPresented = false
                        }
                    } label: {
                        HStack {
                            Text(network.description)
                            Spacer()
                            if viewModel.networkType == network {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Network")
            .navigationBarItems(trailing: Button("Cancel") {
                isPresented = false
            })
        }
    }
}

extension Network: CustomStringConvertible {
    public var description: String {
        switch self {
        case .mainnet: return "Mainnet"
        case .arabica: return "Arabica"
        case .mocha: return "Mocha"
        case .custom(let id): return "Custom: \(id)"
        }
    }
}

struct EventsView: View {
    let events: [NodeEvent]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Node Events")
                .font(.headline)
                .padding(.bottom, 4)
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                            Text(eventDescription(event))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .onChange(of: events.count) { oldCount, newCount in
                        if !events.isEmpty {
                            withAnimation {
                                proxy.scrollTo(events.count - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private func eventDescription(_ event: NodeEvent) -> String {
       switch event {
       case .connectingToBootnodes:
           return "🔄 Connecting to bootnodes"
       case .peerConnected(let id, let trusted):
           return "✅ Peer connected: \(id.peerId) (trusted: \(trusted))"
       case .peerDisconnected(let id, let trusted):
           return "❌ Peer disconnected: \(id.peerId) (trusted: \(trusted))"
       case .samplingStarted(let height, let width, _):
           return "📊 Starting sampling at height \(height) (width: \(width))"
       case .samplingFinished(let height, let accepted, let ms):
           return "✔️ Sampling finished at \(height) (accepted: \(accepted)) [\(ms)ms]"
       case .fetchingHeadersStarted(let from, let to):
           return "📥 Fetching headers \(from)-\(to)"
       case .fetchingHeadersFinished(let from, let to, let ms):
           return "✅ Headers synced \(from)-\(to) [\(ms)ms]"
       case .fetchingHeadersFailed(let from, let to, let error, _):
           return "❌ Sync failed \(from)-\(to): \(error)"
       
       default:
           return "Event: \(String(describing: event))"
       }
   }
}

#Preview {
    ContentView()
}
