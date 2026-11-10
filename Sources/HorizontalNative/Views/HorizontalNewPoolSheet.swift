import SwiftUI
import HorizontalProjectIO
#if os(macOS)
import AppKit
#endif

/// Pools > New Pool…: a new, empty Horizon pool in a folder the user picks,
/// registered so it is browsed with the others and the New menu saves into
/// it. Its pool.json is the one Horizon's pool manager writes
/// (`HorizontalPoolCreation`), and the pools it includes are chosen here
/// from the registered ones, so its parts can use their packages.
struct HorizontalNewPoolSheet: View {
    /// Called with the new pool once it is registered.
    var onCreated: (HorizontalRegisteredPool) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = HorizontalPoolRegistry.shared
    @State private var name = ""
    @State private var includedUUIDs = Set<String>()
    @State private var isChoosingFolder = false
    @State private var failure: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The registered pools a new pool can include: each uuid once, and not
    /// a project pool's shared one.
    private var includablePools: [HorizontalRegisteredPool] {
        var seen = Set<String>()
        return registry.pools.filter { pool in
            let uuid = pool.uuid.lowercased()
            return !uuid.isEmpty && uuid != HorizontalProjectArchive.projectPoolUUID && seen.insert(uuid).inserted
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    Text("The pool goes into the folder you choose next if it is empty, else into a new folder named after it there.")
                }
                if !includablePools.isEmpty {
                    Section {
                        ForEach(includablePools) { pool in
                            Toggle(pool.name, isOn: Binding(
                                get: { includedUUIDs.contains(pool.uuid.lowercased()) },
                                set: { on in
                                    if on { includedUUIDs.insert(pool.uuid.lowercased()) } else { includedUUIDs.remove(pool.uuid.lowercased()) }
                                }
                            ))
                        }
                    } header: {
                        Text("Included Pools")
                    } footer: {
                        Text("Items in the new pool can use the units, packages and padstacks of the pools it includes.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Pool")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose Folder…", action: chooseFolder)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 300)
        #endif
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder):
                // The picker's grant lives while the scope is open; keep it
                // so the registry can mint the new pool's bookmark.
                _ = folder.startAccessingSecurityScopedResource()
                create(at: HorizontalPoolCreation.destination(inChosenFolder: folder, name: trimmedName))
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
        .alert("Could Not Create Pool", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func chooseFolder() {
        #if os(macOS)
        // The save panel names the pool's own folder, and grants it.
        let panel = NSSavePanel()
        panel.title = "New Pool"
        panel.prompt = "Create"
        panel.message = "Choose where the pool “\(trimmedName)” goes. Its folder must be new or empty."
        panel.nameFieldStringValue = HorizontalPoolItemFactory.slug(trimmedName, fallback: "pool")
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            create(at: url)
        }
        #else
        isChoosingFolder = true
        #endif
    }

    private func create(at directory: URL) {
        do {
            let pool = try HorizontalPoolCreation.createAndRegister(
                at: directory,
                name: trimmedName,
                includedPools: includablePools.map { $0.uuid.lowercased() }.filter(includedUUIDs.contains)
            )
            dismiss()
            onCreated(pool)
        } catch {
            failure = error.localizedDescription
        }
    }
}
