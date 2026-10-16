import UIKit

/// Uses the same local visit records as address suggestions; selecting one opens a new tab.
final class BrowsingHistoryController: UITableViewController, UISearchResultsUpdating {
    private let source: MobileAddressSuggestions
    private let open: (URL) -> Void
    private let search = UISearchController(searchResultsController: nil)
    private(set) var entries: [HistoryEntry] = []

    init(source: MobileAddressSuggestions, open: @escaping (URL) -> Void) {
        self.source = source
        self.open = open
        super.init(style: .insetGrouped)
        title = "History"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Visit")
        tableView.rowHeight = 68
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = "Search history"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        reload(query: "")
    }

    func updateSearchResults(for searchController: UISearchController) { reload(query: searchController.searchBar.text ?? "") }

    func reload(query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        entries = source.history.entries.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)
        }.sorted { $0.lastVisited > $1.lastVisited }
        let empty = UILabel()
        empty.text = query.isEmpty ? "No browsing history yet" : "No matching history"
        empty.font = .preferredFont(forTextStyle: .body)
        empty.textColor = .secondaryLabel
        empty.textAlignment = .center
        tableView.backgroundView = entries.isEmpty ? empty : nil
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row], cell = tableView.dequeueReusableCell(withIdentifier: "Visit", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = entry.title.isEmpty ? AddressSuggestionRow.displayAddress(entry.url) : entry.title
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 1
        content.secondaryText = AddressSuggestionRow.displayAddress(entry.url)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 1
        content.image = source.icons.image(for: URL(string: entry.url), fetch: false) ?? UIImage(systemName: "globe")
        content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
        content.imageProperties.cornerRadius = 24*FaviconView.cornerRadiusFraction
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let url = URL(string: entries[indexPath.row].url) else { return }
        let open = open
        // Dismiss the whole navigation stack, including an active search controller.
        navigationController?.presentingViewController?.dismiss(animated: true) { open(url) }
    }
}
