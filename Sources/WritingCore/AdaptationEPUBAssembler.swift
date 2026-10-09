import Foundation
import NovelDocumentCore
import ZIPFoundation

struct AdaptationEPUBAssembler {
  typealias Node = AdaptationXML.Node
  func write(_ assembly: AdaptationAssembly, originalURL: URL?, to destination: URL) throws {
    var files: [String: Data] = [:]
    var packagePath = "EPUB/package.opf"
    if let originalURL {
      let archive = try Archive(url: originalURL, accessMode: .read)
      var total: UInt64 = 0
      var seen: Set<String> = []
      for entry in archive {
        let path = try safePath(entry.path)
        guard entry.type == .file || entry.type == .directory, path == entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
          seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted, seen.count <= 50_000
        else { throw AdaptationAssemblyError.unsafeArchive }
        if entry.type == .directory { continue }
        total += entry.uncompressedSize
        guard entry.uncompressedSize <= 20 * 1_048_576, total <= 200 * 1_048_576 else { throw AdaptationAssemblyError.unsafeArchive }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
          guard data.count + chunk.count <= 20 * 1_048_576 else { throw AdaptationAssemblyError.unsafeArchive }
          data.append(chunk)
        }
        files[path] = data
      }
      guard files["META-INF/rights.xml"] == nil, files["META-INF/encryption.xml"] == nil,
        files["mimetype"] == Data("application/epub+zip".utf8), let container = files["META-INF/container.xml"],
        let rootfile = try AdaptationXML.parse(container).descendants("rootfile").first?.attributes["full-path"]
      else { throw AdaptationAssemblyError.invalidEPUB }
      packagePath = try safePath(rootfile)
    } else {
      files["mimetype"] = Data("application/epub+zip".utf8)
      files["META-INF/container.xml"] = Data("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"EPUB/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)
      files[packagePath] = Data("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"book-id\"></dc:identifier><dc:title></dc:title><dc:language>zh-CN</dc:language></metadata><manifest></manifest><spine></spine></package>".utf8)
    }
    guard let packageData = files[packagePath] else { throw AdaptationAssemblyError.invalidEPUB }
    let package = try AdaptationXML.parse(packageData)
    guard let manifest = package.descendants("manifest").first, let spine = package.descendants("spine").first,
      let metadata = package.descendants("metadata").first else { throw AdaptationAssemblyError.invalidEPUB }
    let base = packagePath.split(separator: "/").dropLast().joined(separator: "/")
    var items: [String: Node] = [:], hrefIDs: [String: String] = [:]
    for item in manifest.children where item.local == "item" {
      guard let id = item.attributes["id"], !id.isEmpty, items[id] == nil, let href = item.attributes["href"] else { throw AdaptationAssemblyError.invalidEPUB }
      items[id] = item
      // Remote resources may be retained, but may never become local paths.
      if href.contains("://") { continue }
      let path = try resolve(href, base: base)
      guard hrefIDs[path] == nil else { throw AdaptationAssemblyError.invalidEPUB }
      hrefIDs[path] = id
    }
    var sequence: [(chapter: AdaptationAssemblyChapter, path: String, id: String)] = []
    var freshIDs: Set<String> = []
    for (index, chapter) in assembly.chapters.enumerated() {
      let path: String, id: String
      if originalURL != nil, !chapter.isNew {
        guard let originalPath = chapter.sourceHref, let existing = hrefIDs[originalPath], files[originalPath] != nil else { throw AdaptationAssemblyError.invalidEPUB }
        path = originalPath; id = existing
        guard spine.children.contains(where: { $0.local == "itemref" && $0.attributes["idref"] == id }) else { throw AdaptationAssemblyError.invalidEPUB }
      } else {
        let stem = "adaptation-" + assembly.variantID.uuidString.lowercased() + "-" + String(format: "%05d", index + 1)
        var suffix = 0
        var candidateID = stem, candidatePath = joined(base, stem + ".xhtml")
        while files.keys.contains(where: { $0.lowercased() == candidatePath.lowercased() }) || items[candidateID] != nil {
          suffix += 1; candidateID = stem + "-\(suffix)"; candidatePath = joined(base, candidateID + ".xhtml")
        }
        path = candidatePath; id = candidateID; freshIDs.insert(id)
        let item = Node("item", ["xmlns": "http://www.idpf.org/2007/opf", "id": id, "href": relative(path, from: base), "media-type": "application/xhtml+xml"])
        manifest.children.append(item); items[id] = item
      }
      if chapter.changed || originalURL == nil {
        files[path] = try chapterPage(chapter, previous: files[path])
      }
      sequence.append((chapter, path, id))
    }
    if originalURL == nil {
      spine.children = sequence.map { Node("itemref", ["xmlns": "http://www.idpf.org/2007/opf", "idref": $0.id]) }
    } else {
      // Keep all original itemrefs (including non-text resources) in place;
      // only append new chapter refs immediately after their source itemref.
      var augmented: [Node] = []
      for child in spine.children {
        augmented.append(child)
        guard child.local == "itemref", let id = child.attributes["idref"],
          let source = sequence.first(where: { $0.id == id && !$0.chapter.isNew }) else { continue }
        for addition in sequence where addition.chapter.isNew && addition.chapter.sourceChapterID == source.chapter.sourceChapterID {
          augmented.append(Node(child.name, ["xmlns": "http://www.idpf.org/2007/opf", "idref": addition.id]))
        }
      }
      spine.children = augmented
      let installed = spine.children.compactMap { $0.attributes["idref"] }
      guard freshIDs.isSubset(of: Set(installed)) else { throw AdaptationAssemblyError.invalidEPUB }
    }
    if package.attributes["version"]?.hasPrefix("3") == true {
      let modified = metadata.descendants("meta").first { $0.attributes["property"] == "dcterms:modified" }
        ?? Node("meta", ["xmlns": "http://www.idpf.org/2007/opf", "property": "dcterms:modified"])
      if !metadata.children.contains(where: { $0 === modified }) { metadata.children.append(modified) }
      modified.setText(ISO8601DateFormatter().string(from: AdaptationCoding.timestamp()))
    }
    // Give the new direction its own publication identity and visible title.
    let titles = metadata.descendants("title")
    if let title = titles.first { title.setText(assembly.title) }
    else { metadata.children.append(element("dc:title", assembly.title)); metadata.attributes["xmlns:dc"] = "http://purl.org/dc/elements/1.1/" }
    let identityID = package.attributes["unique-identifier"] ?? "adaptation-id"
    package.attributes["unique-identifier"] = identityID
    if let identifier = metadata.descendants("identifier").first(where: { $0.attributes["id"] == identityID }) {
      identifier.setText("urn:uuid:" + assembly.variantID.uuidString.lowercased())
    } else {
      let identifier = element("dc:identifier", "urn:uuid:" + assembly.variantID.uuidString.lowercased())
      identifier.attributes["id"] = identityID; metadata.children.append(identifier)
      metadata.attributes["xmlns:dc"] = "http://purl.org/dc/elements/1.1/"
    }
    let navItem = manifest.children.first { ($0.attributes["properties"] ?? "").split(separator: " ").contains("nav") }
    let ncxItem = manifest.children.first { $0.attributes["media-type"] == "application/x-dtbncx+xml" }
    func navigationItem(_ existing: Node?, stem: String, type: String, properties: String? = nil) throws -> (Node, String) {
      if let existing, let href = existing.attributes["href"] { return (existing, try resolve(href, base: base)) }
      var name = stem, suffix = 0
      while files[joined(base, name)] != nil || items[name] != nil { suffix += 1; name = "\(suffix)-" + stem }
      var attributes = ["xmlns": "http://www.idpf.org/2007/opf", "id": name, "href": name, "media-type": type]
      if let properties { attributes["properties"] = properties }
      let node = Node("item", attributes); manifest.children.append(node); items[name] = node
      return (node, joined(base, name))
    }
    let (_, navPath) = try navigationItem(navItem, stem: "nav.xhtml", type: "application/xhtml+xml", properties: "nav")
    let (ncx, ncxPath) = try navigationItem(ncxItem, stem: "toc.ncx", type: "application/x-dtbncx+xml")
    spine.attributes["toc"] = ncx.attributes["id"]
    files[navPath] = try navigation(assembly, sequence: sequence, path: navPath, previous: files[navPath])
    files[ncxPath] = try ncxNavigation(assembly, sequence: sequence, path: ncxPath, previous: files[ncxPath])
    files[packagePath] = AdaptationXML.bytes(package)
    guard files.values.reduce(0, { $0 + $1.count }) <= 200 * 1_048_576 else { throw AdaptationAssemblyError.unsafeArchive }
    let output = try Archive(url: destination, accessMode: .create)
    for path in ["mimetype"] + files.keys.filter({ $0 != "mimetype" }).sorted() {
      guard let data = files[path] else { throw AdaptationAssemblyError.invalidEPUB }
      try output.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
        modificationDate: Date(timeIntervalSince1970: 1_700_000_000), compressionMethod: path == "mimetype" ? .none : .deflate) { position, size in
        data.subdata(in: Int(position)..<Int(position) + size)
      }
    }
    let parsed = try EPUBNovelParser().parse(at: destination)
    guard parsed.title == assembly.title, parsed.chapters.count == sequence.count else { throw AdaptationAssemblyError.invalidEPUB }
    for (actual, expected) in zip(parsed.chapters, sequence) {
      guard actual.sourceHref == expected.path, actual.title == expected.chapter.title,
        actual.content == normalize(expected.chapter.content) else { throw AdaptationAssemblyError.invalidEPUB }
    }
  }

  private func chapterPage(_ chapter: AdaptationAssemblyChapter, previous: Data?) throws -> Data {
    let page: Node
    if let previous { page = try AdaptationXML.parse(previous) }
    else {
      page = Node("html", ["xmlns": "http://www.w3.org/1999/xhtml", "xml:lang": "zh-CN"])
      let head = Node("head"); head.children = [element("title", chapter.title)]
      page.children = [head, Node("body")]
    }
    guard let body = page.descendants("body").first else { throw AdaptationAssemblyError.invalidEPUB }
    body.attributes["xmlns"] = "http://www.w3.org/1999/xhtml"
    page.descendants("title").first?.setText(chapter.title)
    // Edited body is rebuilt from approved plain text. Keep old fragment IDs
    // so inbound links remain resolvable; preserve head/styles/body attributes.
    let ids = descendants(body).compactMap { $0 === body ? nil : $0.attributes["id"] }
    guard Set(ids).count == ids.count else { throw AdaptationAssemblyError.invalidEPUB }
    body.children = ids.map { Node("span", ["id": $0]) }
    body.children.append(element("h1", chapter.title))
    for line in chapter.content.components(separatedBy: "\n") {
      // Paragraph tags render on external readers; blank lines also preserve
      // the parser's plain-text paragraph spacing. Text is never markup.
      body.children.append(line.isEmpty ? Node("", text: "\n") : element("p", line))
    }
    return AdaptationXML.bytes(page)
  }
  private func navigation(_ assembly: AdaptationAssembly, sequence: [(chapter: AdaptationAssemblyChapter, path: String, id: String)], path: String, previous: Data?) throws -> Data {
    let base = path.split(separator: "/").dropLast().joined(separator: "/")
    let links = sequence.map { "<li><a href=\"\(AdaptationXML.escape(relative($0.path, from: base)))\">\(AdaptationXML.escape($0.chapter.title))</a></li>" }.joined()
    let data = Data(("<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>目录</title></head><body><nav epub:type=\"toc\" id=\"toc\"><h1>目录</h1><ol>" + links + "</ol></nav></body></html>").utf8)
    guard let previous else { return data }
    let old = try AdaptationXML.parse(previous), fresh = try AdaptationXML.parse(data)
    guard let toc = old.descendants("nav").first(where: { ($0.attributes["epub:type"] ?? "").split(separator: " ").contains("toc") }) ?? old.descendants("nav").first,
      let newList = fresh.descendants("ol").first else { throw AdaptationAssemblyError.invalidEPUB }
    old.attributes["xmlns:epub"] = "http://www.idpf.org/2007/ops"; toc.attributes["epub:type"] = "toc"
    if let list = toc.descendants("ol").first { list.attributes["xmlns"] = "http://www.w3.org/1999/xhtml"; list.children = newList.children }
    else { toc.attributes["xmlns"] = "http://www.w3.org/1999/xhtml"; toc.children = [element("h1", "目录"), newList] }
    return AdaptationXML.bytes(old)
  }
  private func ncxNavigation(_ assembly: AdaptationAssembly, sequence: [(chapter: AdaptationAssemblyChapter, path: String, id: String)], path: String, previous: Data?) throws -> Data {
    let base = path.split(separator: "/").dropLast().joined(separator: "/")
    let points = sequence.enumerated().map { index, item in
      "<navPoint id=\"point-\(index + 1)\" playOrder=\"\(index + 1)\"><navLabel><text>\(AdaptationXML.escape(item.chapter.title))</text></navLabel><content src=\"\(AdaptationXML.escape(relative(item.path, from: base)))\"/></navPoint>"
    }.joined()
    let data = Data(("<?xml version=\"1.0\"?><ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head><meta name=\"dtb:uid\" content=\"urn:uuid:\(assembly.variantID.uuidString.lowercased())\"/><meta name=\"dtb:depth\" content=\"1\"/><meta name=\"dtb:totalPageCount\" content=\"0\"/><meta name=\"dtb:maxPageNumber\" content=\"0\"/></head><docTitle><text>\(AdaptationXML.escape(assembly.title))</text></docTitle><navMap>" + points + "</navMap></ncx>").utf8)
    guard let previous else { return data }
    let old = try AdaptationXML.parse(previous), fresh = try AdaptationXML.parse(data)
    old.attributes["xmlns"] = "http://www.daisy.org/z3986/2005/ncx/"; old.attributes["version"] = "2005-1"
    for name in ["navmap", "doctitle"] {
      guard let replacement = fresh.descendants(name).first else { throw AdaptationAssemblyError.invalidEPUB }
      if let existing = old.descendants(name).first { existing.children = replacement.children }
      else { old.children.append(replacement) }
    }
    if let head = old.descendants("head").first {
      let reserved = Set(["dtb:uid", "dtb:depth", "dtb:totalPageCount", "dtb:maxPageNumber"])
      head.children.removeAll { reserved.contains($0.attributes["name"] ?? "") }
      head.children += fresh.descendants("head").first?.children ?? []
    } else if let head = fresh.descendants("head").first { old.children.insert(head, at: 0) }
    return AdaptationXML.bytes(old)
  }
  private func element(_ name: String, _ text: String) -> Node { let node = Node(name); node.setText(text); return node }
  private func descendants(_ node: Node) -> [Node] { [node] + node.children.flatMap(descendants) }
  private func joined(_ base: String, _ leaf: String) -> String { base.isEmpty ? leaf : base + "/" + leaf }
  private func safePath(_ path: String) throws -> String {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { throw AdaptationAssemblyError.unsafeArchive }
    var parts: [String] = []
    for part in path.split(separator: "/") {
      if part == "." { continue }
      if part == ".." { guard !parts.isEmpty else { throw AdaptationAssemblyError.unsafeArchive }; parts.removeLast() }
      else { parts.append(String(part)) }
    }
    guard !parts.isEmpty else { throw AdaptationAssemblyError.unsafeArchive }
    return parts.joined(separator: "/")
  }
  private func resolve(_ href: String, base: String) throws -> String {
    guard !href.contains("://"), !href.hasPrefix("/"), let decoded = href.components(separatedBy: "#")[0].removingPercentEncoding else { throw AdaptationAssemblyError.unsafeArchive }
    return try safePath(joined(base, decoded))
  }
  private func relative(_ path: String, from base: String) -> String {
    var target = path.split(separator: "/").map(String.init), origin = base.split(separator: "/").map(String.init)
    while !target.isEmpty && !origin.isEmpty && target[0] == origin[0] { target.removeFirst(); origin.removeFirst() }
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?%"))
    return (Array(repeating: "..", count: origin.count) + target.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }).joined(separator: "/")
  }
  private func normalize(_ text: String) -> String {
    text.replacingOccurrences(of: "[ \\t\\u{00a0}]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
      .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
