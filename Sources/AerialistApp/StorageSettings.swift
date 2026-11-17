import AerialCore
import SwiftUI

/// Settings → Storage: "Delete shown aerials", "Keep the last N", what is on this Mac, and the traffic estimate.
struct StorageSection: View {
    @Environment(AppModel.self) private var model
    /// Turning deletion on with videos already beyond the last N: what would go, waiting for "Keep" or "Delete".
    @ViewState private var pendingEnable: [LocalVideo]?
    /// Lowering N would delete more than one video: the new N and what would go.
    @ViewState private var pendingKeep: PendingKeep?
    @ViewState private var showingList = false

    struct PendingKeep: Equatable {
        let keep: Int
        let videos: [LocalVideo]
    }

    var body: some View {
        Section(L.t("Storage")) {
            // The dialogs and the sheet hang on rows, not on the Section: in a Form a Section's modifiers can be
            // handed to every row.
            Toggle(isOn: Binding(get: { model.state.deleteShown }, set: { setDeleteShown($0) })) {
                Text(L.t("Delete Shown Aerials"))
                Text(L.t("Before a change the next video is downloaded; after it, older ones are deleted. Videos you keep on this Mac and your own videos stay."))
            }
            .confirmationDialog(
                L.t("Delete %@ already on this Mac?", L.videos(pendingEnable?.count ?? 0)),
                isPresented: Binding(get: { pendingEnable != nil }, set: { if !$0 { pendingEnable = nil } })
            ) {
                Button(L.t("Keep Them")) {
                    if let videos = pendingEnable { model.keepExisting(videos) }
                    model.setDeleteShown(true)
                    pendingEnable = nil
                }
                .keyboardShortcut(.defaultAction)
                Button(L.t("Delete Them"), role: .destructive) {
                    let videos = pendingEnable ?? []
                    model.setDeleteShown(true)
                    pendingEnable = nil
                    Task { await model.deleteExisting(videos, keep: model.state.keepLast) }
                }
                Button(L.t("Cancel"), role: .cancel) { pendingEnable = nil }
            } message: {
                Text(enableMessage)
            }
            Picker(selection: Binding(get: { model.state.keepLast }, set: { setKeep($0) })) {
                ForEach(RotationState.keepChoices, id: \.self) { Text(verbatim: "\($0)").tag($0) }
            } label: {
                Text(L.t("Keep the Last"))
                Text(L.t("Videos you keep on this Mac don’t count. Without the network, videos already on this Mac rotate."))
            }
            .pickerStyle(.segmented)
            .disabled(!model.state.deleteShown)
            .confirmationDialog(
                L.t("Delete %@ now?", L.videos(pendingKeep?.videos.count ?? 0)),
                isPresented: Binding(get: { pendingKeep != nil }, set: { if !$0 { pendingKeep = nil } })
            ) {
                Button(L.t("Delete"), role: .destructive) {
                    if let keep = pendingKeep?.keep { Task { await model.setKeepLast(keep) } }
                    pendingKeep = nil
                }
                Button(L.t("Cancel"), role: .cancel) { pendingKeep = nil }
            } message: {
                Text(L.t("They total %@. They stay in your playlists and are downloaded again for their turn.",
                         AppModel.size(bytes(pendingKeep?.videos), language: model.language)))
            }
            LabeledContent {
                HStack(spacing: 10) {
                    Text(verbatim: "\(L.videos(model.local.count)) · \(AppModel.size(model.totalDownloadedBytes, language: model.language))")
                        .foregroundStyle(.primary)
                    Button(L.t("Show…")) { showingList = true }
                }
            } label: {
                Text(L.t("On This Mac"))
            }
            .sheet(isPresented: $showingList) { OnThisMacList() }
            LabeledContent {
                Text(L.t("About %@ a month", AppModel.size(model.monthlyTraffic, language: model.language)))
                    .foregroundStyle(.primary)
            } label: {
                Text(L.t("Traffic"))
                Text(L.t("If every video has to be downloaded. Without the network, in Low Data Mode or Low Power Mode, scheduled changes show videos already on this Mac."))
            }
        }
    }

    /// Size, what happens to the videos, and the Trash only when some of them are the user's earlier downloads.
    private var enableMessage: String {
        let videos = pendingEnable ?? []
        let copies = Set(model.state.streamedIDs)
        var text = L.t("They total %@. They stay in your playlists and are downloaded again for their turn.",
                       AppModel.size(bytes(videos), language: model.language))
        if videos.contains(where: { !copies.contains($0.assetID) }) {
            text += " " + L.t("Videos you downloaded earlier go to the Trash.")
        }
        return text
    }

    private func bytes(_ videos: [LocalVideo]?) -> Int64 { (videos ?? []).reduce(0) { $0 + $1.size } }

    private func setDeleteShown(_ on: Bool) {
        guard on else {
            model.setDeleteShown(false)
            return
        }
        model.refresh()
        // Without the wallpaper settings nothing can be checked, so deletion doesn't go on unasked.
        guard model.referencedIDs != nil else {
            model.windowError = L.t("Can’t check which videos are in use, so they stay.")
            return
        }
        let excess = model.excess(keep: model.state.keepLast)
        if excess.isEmpty { model.setDeleteShown(true) } else { pendingEnable = excess }
    }

    private func setKeep(_ keep: Int) {
        guard model.state.deleteShown, keep < model.state.keepLast else {
            Task { await model.setKeepLast(keep) }
            return
        }
        model.refresh()
        let going = model.excessOfRotationCopies(keep: keep)
        if going.count > 1 { pendingKeep = PendingKeep(keep: keep, videos: going) } else { Task { await model.setKeepLast(keep) } }
    }
}

/// Settings → Storage → On This Mac → Show…: every video file on this Mac, with what keeps it and a way to remove it.
struct OnThisMacList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("On This Mac")).font(.headline)
            List(videos, id: \.assetID) { video in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name(of: video.assetID) ?? video.assetID).lineLimit(1)
                        Text(verbatim: details(video)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L.t("Remove")) { model.moveToTrash(video.assetID) }
                        .disabled(!canRemove(video.assetID))
                        .help(canRemove(video.assetID) ? L.t("Moves the file to the Trash") : L.t("In use, or one of your own videos"))
                }
            }
            .frame(minHeight: 260)
            HStack {
                Button(L.t("Show in Finder")) { NSWorkspace.shared.open(model.paths.videos) }
                Spacer()
                Button(L.t("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private var videos: [LocalVideo] { model.local.values.sorted { $0.size > $1.size } }

    private func canRemove(_ id: String) -> Bool {
        !model.isInUse(id) && model.catalog?.asset(id)?.isCustom == false
    }

    /// Size and why the file is here: on screen, kept, recently shown, your own video, or downloaded by macOS.
    private func details(_ video: LocalVideo) -> String {
        var parts = [AppModel.size(video.size, language: model.language)]
        let id = video.assetID
        if id == model.currentAssetID { parts.append(L.t("On Screen")) }
        if model.isPinned(id) { parts.append(L.t("Kept on This Mac")) }
        if model.catalog?.asset(id)?.isCustom == true || model.customIDs.contains(id) { parts.append(L.t("Your video")) }
        if model.isInMyAerials(id) { parts.append(L.t("In My Aerials")) }
        return parts.joined(separator: " · ")
    }
}
