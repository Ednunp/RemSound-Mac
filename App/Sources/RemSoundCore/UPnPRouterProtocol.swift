import Foundation

struct UPnPRouterService: Hashable {
    enum Kind: String, CaseIterable {
        case ip1 = "urn:schemas-upnp-org:service:WANIPConnection:1"
        case ip2 = "urn:schemas-upnp-org:service:WANIPConnection:2"
        case ppp1 = "urn:schemas-upnp-org:service:WANPPPConnection:1"
    }
    let kind: Kind, controlURL: URL, gatewayAddress: String
}
struct UPnPSOAPRequest { let url: URL, soapAction: String, body: Data }
struct UPnPPortMapping: Equatable {
    let internalPort: UInt16, internalClient: String, enabled: Bool, description: String, leaseSeconds: UInt32
}
enum UPnPMappingPreflight: Equatable { case available, occupied(UPnPPortMapping), unavailable }
enum UPnPSOAPReply: Equatable { case mapping(UPnPPortMapping), success(externalAddress: String?), fault(code: UInt16, description: String) }

enum UPnPRouterProtocol {
    enum Action: String { case specificMapping = "GetSpecificPortMappingEntry", add = "AddPortMapping", delete = "DeletePortMapping", externalIP = "GetExternalIPAddress" }
    static let igd1 = "urn:schemas-upnp-org:device:InternetGatewayDevice:1"
    static let igd2 = "urn:schemas-upnp-org:device:InternetGatewayDevice:2"
    static let maximumDescriptionBytes = 256 * 1024
    static let maximumSOAPBytes = 64 * 1024
    static let maximumSSDPBytes = 16 * 1024
    private static let deviceNamespace = "urn:schemas-upnp-org:device-1-0"
    private static let soapNamespace = "http://schemas.xmlsoap.org/soap/envelope/"
    private static let controlNamespace = "urn:schemas-upnp-org:control-1-0"
    private static let maximumServices = 8
    private static let maximumSSDPLines = 64
    private static let maximumHeaderBytes = 4096
    private static let maximumURLBytes = 2048
    private static let maximumFaultCharacters = 256
    private static let maximumLeaseSeconds: UInt32 = 604800
    private static let maximumMappingDescriptionCharacters = 64
    private static let targets = Set([igd1, igd2] + UPnPRouterService.Kind.allCases.map(\.rawValue))
    static func search(target: String = igd1, mx: Int = 2) -> Data? {
        guard targets.contains(target), (1...5).contains(mx) else { return nil }
        return Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: \(mx)\r\nST: \(target)\r\n\r\n".utf8)
    }
    static func unicastSearch(gatewayAddress: String, target: String = igd1) -> Data? {
        guard RouterMappingPackets.ipv4(gatewayAddress) != nil, targets.contains(target) else { return nil }
        return Data("M-SEARCH * HTTP/1.1\r\nHOST: \(gatewayAddress):1900\r\nMAN: \"ssdp:discover\"\r\nST: \(target)\r\n\r\n".utf8)
    }
    static func discovery(_ data: Data, from: Endpoint, gatewayAddress: String, searchTarget: String? = nil) -> URL? {
        guard from.address == gatewayAddress, from.port > 0, data.count <= maximumSSDPBytes,
              let text = String(data: data, encoding: .utf8), text.hasSuffix("\r\n\r\n"),
              text.range(of: "\r\n\r\n")?.upperBound == text.endIndex else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.count <= maximumSSDPLines, lines.first == "HTTP/1.1 200 OK" || lines.first == "HTTP/1.0 200 OK" else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst().dropLast(2) {
            guard line.utf8.count <= maximumHeaderBytes, let colon = line.firstIndex(of: ":"),
                  line.first != " ", line.first != "\t" else { return nil }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
                  headers[name] == nil else { return nil }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            headers[name] = value
        }
        guard let target = headers["st"], targets.contains(target), searchTarget.map({ $0 == target }) ?? true, let usn = headers["usn"], !usn.isEmpty,
              let location = headers["location"] else { return nil }
        return localURL(location, gateway: gatewayAddress)
    }
    static func services(_ data: Data, location: URL, gatewayAddress: String) -> [UPnPRouterService] {
        guard let location = localURL(location.absoluteString, gateway: gatewayAddress),
              let root = Tree.read(data, maximumBytes: maximumDescriptionBytes),
              root.name == "root", root.namespace == deviceNamespace,
              let device = root.one("device", deviceNamespace),
              let type = device.one("deviceType", deviceNamespace)?.leaf, [igd1, igd2].contains(type) else { return [] }
        let bases = root.children.filter { $0.name == "URLBase" && $0.namespace == deviceNamespace }
        guard bases.count <= 1 else { return [] }
        let base: URL
        if let declared = bases.first {
            guard let value = declared.leaf, let parsed = localURL(value, gateway: gatewayAddress, scheme: location.scheme) else { return [] }
            base = parsed
        } else { base = location }
        var result = Set<UPnPRouterService>()
        for wan in devices(device) where family(wan, "WANDevice") {
            for connection in devices(wan) where family(connection, "WANConnectionDevice") {
                guard let list = connection.one("serviceList", deviceNamespace) else { continue }
                for entry in list.children where entry.name == "service" && entry.namespace == deviceNamespace {
                    guard let value = entry.one("serviceType", deviceNamespace)?.leaf,
                          let kind = UPnPRouterService.Kind(rawValue: value),
                          let control = entry.one("controlURL", deviceNamespace)?.leaf,
                          let url = URL(string: control, relativeTo: base)?.absoluteURL,
                          let safe = localURL(url.absoluteString, gateway: gatewayAddress, scheme: location.scheme) else { continue }
                    result.insert(.init(kind: kind, controlURL: safe, gatewayAddress: gatewayAddress))
                }
            }
        }
        return Array(result.sorted {
            let a = priority($0.kind), b = priority($1.kind)
            return a == b ? $0.controlURL.absoluteString < $1.controlURL.absoluteString : a < b
        }.prefix(maximumServices))
    }
    static func request(_ service: UPnPRouterService, action: Action, internalClient: String? = nil,
                        internalPort: UInt16 = 0, externalPort: UInt16 = 0, leaseSeconds: UInt32 = 3600, mappingDescription: String = "RemSound audio") -> UPnPSOAPRequest? {
        guard let url = localURL(service.controlURL.absoluteString, gateway: service.gatewayAddress) else { return nil }
        var arguments: [(String, String)] = []
        switch action {
        case .externalIP: break
        case .delete, .specificMapping:
            guard externalPort > 0 else { return nil }
            arguments = [("NewRemoteHost", ""), ("NewExternalPort", String(externalPort)), ("NewProtocol", "UDP")]
        case .add:
            guard internalPort > 0, externalPort > 0, let client = internalClient,
                  RouterMappingPackets.ipv4(client) != nil, leaseSeconds <= maximumLeaseSeconds,
                  service.kind != .ip2 || leaseSeconds > 0,
                  !mappingDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  mappingDescription.count <= maximumMappingDescriptionCharacters,
                  !mappingDescription.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            arguments = [("NewRemoteHost", ""), ("NewExternalPort", String(externalPort)), ("NewProtocol", "UDP"),
                         ("NewInternalPort", String(internalPort)), ("NewInternalClient", client), ("NewEnabled", "1"),
                         ("NewPortMappingDescription", mappingDescription), ("NewLeaseDuration", String(leaseSeconds))]
        }
        let body = arguments.map { "<\($0.0)>\(escapeXML($0.1))</\($0.0)>" }.joined()
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"\(soapNamespace)\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action.rawValue) xmlns:u=\"\(service.kind.rawValue)\">\(body)</u:\(action.rawValue)></s:Body></s:Envelope>"
        return .init(url: url, soapAction: "\"\(service.kind.rawValue)#\(action.rawValue)\"", body: Data(xml.utf8))
    }
    private static func escapeXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    static func reply(_ data: Data, status: Int, service: UPnPRouterService, action: Action) -> UPnPSOAPReply? {
        guard status == 200 || status == 500, let envelope = Tree.read(data, maximumBytes: maximumSOAPBytes),
              envelope.name == "Envelope", envelope.namespace == soapNamespace,
              let body = envelope.one("Body", soapNamespace), body.children.count == 1, body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = body.children.first else { return nil }
        if value.name == "Fault", value.namespace == soapNamespace {
            guard let detail = value.namedOnce("detail"), let error = detail.one("UPnPError", controlNamespace),
                  let codeText = error.one("errorCode", controlNamespace)?.leaf, let code = UInt16(codeText), code > 0, String(code) == codeText,
                  let description = error.one("errorDescription", controlNamespace)?.leaf else { return nil }
            let flattened = String(description.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(maximumFaultCharacters))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return .fault(code: code, description: flattened)
        }
        guard status == 200, value.name == action.rawValue + "Response", value.namespace == service.kind.rawValue else { return nil }
        if action == .specificMapping {
            guard value.children.count == 5, value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let portText = value.one("NewInternalPort", "")?.leaf, let port = UInt16(portText), port > 0, String(port) == portText,
                  let client = value.one("NewInternalClient", "")?.leaf, RouterMappingPackets.ipv4(client) != nil,
                  let enabledText = value.one("NewEnabled", "")?.leaf,
                  ["0", "1", "true", "false", "yes", "no"].contains(enabledText),
                  let descriptionNode = value.one("NewPortMappingDescription", ""), descriptionNode.children.isEmpty,
                  descriptionNode.text.count <= maximumFaultCharacters else { return nil }
            // Ownership markers are exact strings; trimming can turn an altered rule
            // into a false match. Other scalar fields still use their normalized parser.
            let description = descriptionNode.text
            guard
                  !description.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let leaseText = value.one("NewLeaseDuration", "")?.leaf, let lease = UInt32(leaseText), String(lease) == leaseText else { return nil }
            return .mapping(.init(internalPort: port, internalClient: client,
                enabled: ["1", "true", "yes"].contains(enabledText), description: description, leaseSeconds: lease))
        }
        if action == .externalIP {
            guard value.children.count == 1, let address = value.one("NewExternalIPAddress", "")?.leaf,
                  RouterMappingPackets.ipv4(address) != nil else { return nil }
            return .success(externalAddress: address)
        }
        guard value.children.isEmpty, value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .success(externalAddress: nil)
    }
    static func preflight(_ reply: UPnPSOAPReply?) -> UPnPMappingPreflight {
        switch reply {
        case .fault(code: 714, description: _): return .available
        case .mapping(let mapping): return .occupied(mapping)
        default: return .unavailable
        }
    }
    static func safeURL(_ url: URL, gateway: String) -> URL? { localURL(url.absoluteString, gateway: gateway) }
    private static func localURL(_ value: String, gateway: String, scheme: String? = nil) -> URL? {
        guard value.utf8.count <= maximumURLBytes, RouterMappingPackets.ipv4(gateway) != nil,
              let decoded = value.removingPercentEncoding, !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value), let protocolName = components.scheme,
              ["http", "https"].contains(protocolName), scheme == nil || scheme == protocolName,
              components.host == gateway, components.user == nil, components.password == nil, components.fragment == nil,
              (1...65535).contains(components.port ?? (protocolName == "https" ? 443 : 80)) else { return nil }
        return components.url
    }
    private static func devices(_ node: Tree.Node) -> [Tree.Node] {
        node.one("deviceList", deviceNamespace)?.children.filter { $0.name == "device" && $0.namespace == deviceNamespace } ?? []
    }
    private static func family(_ node: Tree.Node, _ family: String) -> Bool {
        guard let value = node.one("deviceType", deviceNamespace)?.leaf else { return false }
        return [1, 2].contains { value == "urn:schemas-upnp-org:device:\(family):\($0)" }
    }
    private static func priority(_ kind: UPnPRouterService.Kind) -> Int { switch kind { case .ip2: return 0; case .ip1: return 1; case .ppp1: return 2 } }

    private final class Tree: NSObject, XMLParserDelegate {
        private static let maximumDepth = 32
        private static let maximumNodes = 1024
        private static let maximumTextBytes = 128 * 1024
        final class Node {
            let name: String, namespace: String
            var children: [Node] = [], text = ""
            init(_ name: String, _ namespace: String) { self.name = name; self.namespace = namespace }
            var leaf: String? { children.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            func one(_ name: String, _ namespace: String) -> Node? {
                let matches = children.filter { $0.name == name && $0.namespace == namespace }; return matches.count == 1 ? matches[0] : nil
            }
            func namedOnce(_ name: String) -> Node? {
                let matches = children.filter { $0.name == name }; return matches.count == 1 ? matches[0] : nil
            }
        }
        private var root: Node?, stack: [Node] = []
        private var nodes = 0, textBytes = 0, rejected = false
        static func read(_ data: Data, maximumBytes: Int) -> Node? {
            guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
                  text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                  text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return nil }
            let tree = Tree(), parser = XMLParser(data: data)
            parser.delegate = tree; parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
            guard parser.parse(), !tree.rejected, tree.stack.isEmpty else { return nil }
            return tree.root
        }
        private func reject(_ parser: XMLParser) { rejected = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            nodes += 1
            guard stack.count < Self.maximumDepth, nodes <= Self.maximumNodes else { reject(parser); return }
            let node = Node(elementName, namespaceURI ?? "")
            if let parent = stack.last { parent.children.append(node) }
            else if root == nil { root = node } else { reject(parser); return }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { if !stack.isEmpty { stack.removeLast() } }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBytes += string.utf8.count
            guard textBytes <= Self.maximumTextBytes else { reject(parser); return }
            stack.last?.text += string
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else { reject(parser); return }
            self.parser(parser, foundCharacters: text)
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    }
}
