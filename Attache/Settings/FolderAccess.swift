//
//  FolderAccess.swift
//  Attache
//

import Foundation

// macOS keeps Desktop, Documents and Downloads behind a per-app permission
// (TCC), and there is no public call that reads the current answer without
// risking the prompt. What does work is listing the folder: the first time, the
// system asks the person; every time after, the call just succeeds or fails
// with the answer they gave. So "check" and "request" are the same call here,
// and a denied folder never prompts again — it can only be fixed in System
// Settings, which is why `settingsURL` exists.
//
// This matters for this app because a file dragged out of Downloads onto a pane
// is pasted as a path, and the program in the pane (an agent, usually) then
// opens that path. That program is a descendant of this app, so the permission
// it needs is the one granted to this app.

nonisolated enum ProtectedFolder: CaseIterable, Identifiable {
    case desktop, documents, downloads

    var id: Self { self }

    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc.fill"
        case .downloads: "arrow.down.circle.fill"
        }
    }

    var url: URL {
        let directory: FileManager.SearchPathDirectory = switch self {
        case .desktop: .desktopDirectory
        case .documents: .documentDirectory
        case .downloads: .downloadsDirectory
        }
        return FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(title)
    }
}

nonisolated enum FolderAccess: Equatable {
    case granted
    /// The person said no, or the system said no for them. Asking again does
    /// nothing; only System Settings can change it.
    case denied
    /// The folder is not there (moved, or the account has no such folder), so
    /// there is nothing to grant.
    case missing
    /// The listing failed for a reason that is not a permission answer (out of
    /// file descriptors, an I/O error). Nothing was decided, so asking again is
    /// the right response and System Settings is not.
    case failed(Int32)
}

nonisolated extension ProtectedFolder {
    /// Lists the folder, which shows the system's permission prompt if the
    /// person has never been asked. Blocks until they answer, so call it off the
    /// main thread.
    func probe() -> FolderAccess {
        guard let dir = opendir(url.path) else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case EPERM, EACCES: return .denied
            default: return .failed(errno)
            }
        }
        closedir(dir)
        return .granted
    }

    /// Settings > Privacy & Security > Files & Folders.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    )!
}
