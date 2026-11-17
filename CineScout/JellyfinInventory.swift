import Foundation

struct JellyfinLibrary: Identifiable, Decodable {
    let Id: String
    let Name: String?

    var id: String { Id }
    var name: String { Name ?? "Médiathèque" }
}

struct JellyfinInventory {
    struct Library: Identifiable {
        let folder: JellyfinLibrary
        let count: Int
        var id: String { folder.id }
    }

    let titles: [Media]
    let libraries: [Library]
}

struct JellyfinLibraryClient {
    let server: String
    let userID: String
    let authorization: String
    var session: URLSession = .shared
    var pageSize = 250

    private struct Page<Entry: Decodable>: Decodable {
        let Items: [Entry]
        let TotalRecordCount: Int?
    }

    enum Failure: LocalizedError {
        case http(Int)
        case incomplete
        case noSession

        var errorDescription: String? {
            switch self {
            case .http(401), .http(403): "Jellyfin a refusé l’accès à la médiathèque. Vérifie la session et les droits du compte."
            case .http(let status): "Jellyfin est indisponible (HTTP \(status))."
            case .incomplete: "Jellyfin a renvoyé un inventaire incomplet. Relance la synchronisation."
            case .noSession: "Connecte ton compte Jellyfin pour vérifier les titres déjà présents."
            }
        }
    }

    func inventory() async throws -> JellyfinInventory {
        let views: Page<JellyfinLibrary> = try await get("UserViews", [
            .init(name: "IncludeHidden", value: "true"),
            .init(name: "IncludeExternalContent", value: "false")
        ])
        if let count = views.TotalRecordCount, count > views.Items.count { throw Failure.incomplete }

        var titles: [String: Media] = [:]
        var libraries: [JellyfinInventory.Library] = []
        var seen = Set<String>()
        for folder in views.Items where seen.insert(folder.id).inserted {
            let items = try await readTitles(parent: folder.id)
            libraries.append(.init(folder: folder, count: items.count))
            for item in items { titles[item.id] = item }
        }

        // The root also covers items reached through grouped or specialized views.
        let rootTitles = try await readTitles(parent: nil)
        for item in rootTitles { titles[item.id] = item }
        let sorted = titles.values.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return JellyfinInventory(titles: sorted, libraries: libraries)
    }

    private func readTitles(parent: String?) async throws -> [Media] {
        var filters: [URLQueryItem] = [
            .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Movie,Series,Video"),
            .init(name: "Fields", value: "ProviderIds,Genres,OriginalTitle"),
            .init(name: "EnableUserData", value: "true"),
            .init(name: "EnableImages", value: "false"),
            .init(name: "EnableTotalRecordCount", value: "true"),
            .init(name: "CollapseBoxSetItems", value: "false"),
            .init(name: "ExcludeLocationTypes", value: "Virtual"),
            .init(name: "SortBy", value: "SortName,DateCreated"),
            .init(name: "Limit", value: String(pageSize))
        ]
        if let parent { filters.append(.init(name: "ParentId", value: parent)) }
        var items: [Media] = []
        var seen = Set<String>()
        while true {
            let page: Page<Media> = try await get("Items", filters + [.init(name: "StartIndex", value: String(items.count))])
            try Task.checkCancellation()
            let total = page.TotalRecordCount.flatMap { $0 > 0 ? $0 : nil }
            if page.Items.isEmpty {
                if let total, items.count < total { throw Failure.incomplete }
                return items
            }
            for title in page.Items {
                guard seen.insert(title.id).inserted else { throw Failure.incomplete }
                items.append(title)
            }
            if let total, items.count >= total { return items }
        }
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        guard var parts = URLComponents(string: server + "/" + path) else { throw URLError(.badURL) }
        parts.queryItems = [.init(name: "UserId", value: userID)] + query
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
