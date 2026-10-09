import Foundation

/// Small cross-platform XML tree for OPF/NCX/XHTML updates. Unchanged archive
/// entries are copied as bytes and never pass through this serializer.
final class AdaptationXML: NSObject, XMLParserDelegate {
  final class Node {
    var name: String
    var attributes: [String: String]
    var children: [Node] = []
    var text: String?
    init(_ name: String, _ attributes: [String: String] = [:], text: String? = nil) {
      self.name = name; self.attributes = attributes; self.text = text
    }
    var local: String { name.split(separator: ":").last.map(String.init)?.lowercased() ?? name }
    func descendants(_ local: String) -> [Node] { (self.local == local ? [self] : []) + children.flatMap { $0.descendants(local) } }
    var string: String { text ?? children.map(\.string).joined() }
    func setText(_ value: String) { children = [Node("", text: value)] }
    func xml() -> String {
      if let text { return AdaptationXML.escape(text) }
      let attrs = attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(AdaptationXML.escape($0.value))\"" }.joined()
      return "<" + name + attrs + ">" + children.map { $0.xml() }.joined() + "</" + name + ">"
    }
  }
  private var stack: [Node] = []
  private var root: Node?
  private var size = 0, nodes = 0
  static func parse(_ data: Data) throws -> Node {
    guard data.count <= 20 * 1_048_576 else { throw AdaptationAssemblyError.unsafeArchive }
    let delegate = AdaptationXML()
    let repaired = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "&nbsp;", with: "&#160;").data(using: .utf8) ?? data
    let parser = XMLParser(data: repaired); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
    guard parser.parse(), let root = delegate.root, delegate.stack.isEmpty else { throw AdaptationAssemblyError.invalidEPUB }
    return root
  }
  static func bytes(_ root: Node) -> Data { Data(("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" + root.xml()).utf8) }
  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
    nodes += 1
    guard nodes <= 100_000, stack.count < 128 else { parser.abortParsing(); return }
    let node = Node(elementName, attributes)
    if let parent = stack.last { parent.children.append(node) }
    else if root == nil { root = node } else { parser.abortParsing(); return }
    stack.append(node)
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    size += string.utf8.count
    guard size <= 20 * 1_048_576 else { parser.abortParsing(); return }
    if let last = stack.last?.children.last, last.text != nil { last.text? += string }
    else { stack.last?.children.append(Node("", text: string)) }
  }
  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    guard let text = String(data: CDATABlock, encoding: .utf8) else { parser.abortParsing(); return }
    self.parser(parser, foundCharacters: text)
  }
  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
  func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
  func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
