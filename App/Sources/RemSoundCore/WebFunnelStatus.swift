import CoreFoundation
import CryptoKit
import Foundation

// Parsed CLI values are observations, never permission to run a process, expose
// a listener or open a URL. Raw output stays inside Core and is not logged.
enum WebFunnelStatus {
    static let maximumOutputBytes=131_072,maximumDepth=16,maximumValues=2048
    static let maximumSites=32,maximumStringBytes=8192,maximumKeyBytes=256
    enum Query:Equatable,Sendable {
        case funnel,node,turnOn(UInt16)
        var arguments:[String] {
            switch self {
            case .funnel:return ["funnel","status","--json"]
            case .node:return ["status","--json"]
            case .turnOn(let port):return ["funnel","--bg",String(port)]
            }
        }
    }
    // Only printed initial approval destinations are handed to the browser.
    static let downloadPage=URL(string:"https://tailscale.com/download")!
    static func approvalURL(_ text:String)->URL? {
        let maximumApprovalURLBytes=2048,bytes=Array(text.utf8.prefix(maximumApprovalURLBytes+1))
        guard !bytes.isEmpty,bytes.count<=maximumApprovalURLBytes,text.hasPrefix("https://login.tailscale.com/"),
              bytes.allSatisfy({$0>32 && $0<127 && $0 != 92}) else {return nil}
        func hex(_ b:UInt8)->UInt8? {if b>=48 && b<=57 {return b-48};if b>=65 && b<=70 {return b-55};if b>=97 && b<=102 {return b-87};return nil}
        var index=0
        while index<bytes.count {
            if bytes[index]==37 {
                guard index+2<bytes.count,let a=hex(bytes[index+1]),let b=hex(bytes[index+2]) else {return nil}
                let decoded=a*16+b;guard decoded>32,decoded != 127,decoded != 92,decoded != 37 else {return nil};index += 3
            } else {index += 1}
        }
        guard let c=URLComponents(string:text),c.scheme=="https",c.host=="login.tailscale.com",c.user==nil,c.password==nil,c.port==nil,c.fragment==nil,
              !c.path.hasPrefix("//"),!c.path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0=="." || $0==".."}),
              let url=c.url,url.absoluteString==text else {return nil}
        return url
    }
    struct Address:Equatable,Sendable {
        let url:URL
        fileprivate init(_ url:URL) {self.url=url}
        static func potential(_ node:String)->Self? {guard WebFunnelStatus.hostname(node)==node,let url=URL(string:"https://"+node) else {return nil};return Self(url)}
    }
    enum Funnel:Equatable,Sendable {
        case unknown,noMatchingRoot
        case mapping(address:Address,allowed:Bool)
    }
    struct EnableObservation:Equatable,Sendable {
        let source:UUID,localPort:UInt16,node:String,configurationDigest:Data,wasEmpty:Bool,alreadyAllowed:Bool
        fileprivate init(source:UUID,localPort:UInt16,node:String,configurationDigest:Data,wasEmpty:Bool,alreadyAllowed:Bool) {self.source=source;self.localPort=localPort;self.node=node;self.configurationDigest=configurationDigest;self.wasEmpty=wasEmpty;self.alreadyAllowed=alreadyAllowed}
    }
    enum EnablePreflight:Equatable,Sendable {case unknown,conflict,ready(EnableObservation)}
    // Read-only observations. A byte digest is not the daemon's ETag, an atomic
    // precondition or permission to overwrite shared configuration.
    static func prepareEnable(_ bytes:Data,exitStatus:Int32,localPort:UInt16,node:String,source:UUID)->EnablePreflight {
        guard exitStatus==0,localPort>0,hostname(node)==node,let decoded=read(bytes) else {return .unknown}
        let root:[String:Any]
        if decoded is NSNull {root=[:]} else if let fields=decoded as? [String:Any] {root=fields} else {return .unknown}
        guard Set(root.keys).isSubset(of:["TCP","Web","AllowFunnel","Foreground","Services"]),
              let tcp=fields(root["TCP"]),let web=fields(root["Web"]),let allow=fields(root["AllowFunnel"]),
              let foreground=fields(root["Foreground"]),let services=fields(root["Services"]),
              tcp.count<=maximumSites,web.count<=maximumSites,allow.count<=maximumSites else {return .unknown}
        for value in allow.values {guard boolean(value) != nil else {return .unknown}}
        guard foreground.isEmpty,services.isEmpty else {return .conflict}
        let empty=tcp.isEmpty && web.isEmpty && allow.isEmpty,site="\(node):\(defaultHTTPSPort)"
        var allowed=false
        if !empty {
            guard Set(tcp.keys)==[String(defaultHTTPSPort)],Set(web.keys)==[site],Set(allow.keys).isSubset(of:[site]) else {return .conflict}
            guard let transport=tcp[String(defaultHTTPSPort)] as? [String:Any],let https=boolean(transport["HTTPS"]),
                  let server=web[site] as? [String:Any],let handlers=server["Handlers"] as? [String:Any] else {return .unknown}
            guard https,Set(transport.keys)==["HTTPS"],Set(server.keys)==["Handlers"],Set(handlers.keys)==["/"],
                  let handler=handlers["/"] as? [String:Any],Set(handler.keys)==["Proxy"],let target=handler["Proxy"] as? String,
                  target=="http://127.0.0.1:\(localPort)" || target=="http://127.0.0.1:\(localPort)/" else {return .conflict}
            allowed=allow[site].flatMap{boolean($0)} ?? false
        }
        return .ready(.init(source:source,localPort:localPort,node:node,configurationDigest:Data(SHA256.hash(data:bytes)),wasEmpty:empty,alreadyAllowed:allowed))
    }
    enum Node:Equatable,Sendable {
        case unknown,notReady
        case running(dnsName:String?)
    }
    private static let defaultHTTPSPort:UInt16=443
    private static let publicPorts:Set<UInt16>=[defaultHTTPSPort,8443,10000]
    private static let maximumHostBytes=253,maximumLabelBytes=63,minimumTailnetLabels=4
    private static let maximumPrimitiveBytes=128,asciiLimit:UInt8=128
    static func funnel(_ bytes:Data,exitStatus:Int32,localPort:UInt16)->Funnel {
        guard exitStatus==0,localPort>0,let raw=read(bytes) else {return .unknown}
        if raw is NSNull {return .noMatchingRoot}
        guard let root=raw as? [String:Any],root.isEmpty || !Set(root.keys).isDisjoint(with:["TCP","Web","AllowFunnel","Foreground","Services"]) else {return .unknown}
        for key in ["Foreground","Services"] {
            if let value=root[key],!(value is NSNull) {
                guard let fields=value as? [String:Any],fields.isEmpty else {return .unknown}
            }
        }
        guard let web=fields(root["Web"]),let tcp=fields(root["TCP"]),let allow=fields(root["AllowFunnel"]),
              web.count<=maximumSites,tcp.count<=maximumSites,allow.count<=maximumSites else {return .unknown}
        for value in allow.values {guard boolean(value) != nil else {return .unknown}}
        var match:Funnel?
        for (site,value) in web {
            guard let (address,publicPort)=siteAddress(site),let server=value as? [String:Any],let handlers=fields(server["Handlers"]) else {return .unknown}
            guard let rawHandler=handlers["/"] else {continue}
            guard let handler=rawHandler as? [String:Any] else {return .unknown}
            guard let rawProxy=handler["Proxy"] else {continue}
            guard Set(handler.keys)==["Proxy"],let proxy=rawProxy as? String else {return .unknown}
            let target="http://127.0.0.1:\(localPort)"
            guard proxy==target || proxy==target+"/" else {continue}
            guard match == nil,let transport=tcp[String(publicPort)] as? [String:Any],
                  Set(transport.keys).isSubset(of:["HTTPS","HTTP","TCPForward","TerminateTLS"]),
                  boolean(transport["HTTPS"])==true else {return .unknown}
            if let http=transport["HTTP"] {guard boolean(http)==false else {return .unknown}}
            for key in ["TCPForward","TerminateTLS"] {
                if let value=transport[key] {guard let text=value as? String,text.isEmpty else {return .unknown}}
            }
            match = .mapping(address:address,allowed:allow[site].flatMap{boolean($0)} ?? false)
        }
        return match ?? .noMatchingRoot
    }
    static func node(_ bytes:Data,exitStatus:Int32)->Node {
        guard exitStatus==0,let root=read(bytes) as? [String:Any],let state=root["BackendState"] as? String else {return .unknown}
        if ["Stopped","NeedsLogin","NeedsMachineAuth","Starting"].contains(state) {return .notReady}
        guard state=="Running" else {return .unknown}
        guard let rawSelf=root["Self"],!(rawSelf is NSNull) else {return .running(dnsName:nil)}
        guard let own=rawSelf as? [String:Any] else {return .unknown}
        guard let rawName=own["DNSName"],!(rawName is NSNull) else {return .running(dnsName:nil)}
        guard let name=rawName as? String else {return .unknown}
        if name.isEmpty {return .running(dnsName:nil)}
        let unqualified=name.hasSuffix(".") ? String(name.dropLast()):name
        guard let host=hostname(unqualified) else {return .unknown}
        return .running(dnsName:host)
    }
    private static func fields(_ raw:Any?)->[String:Any]? {
        guard let raw,!(raw is NSNull) else {return [:]};return raw as? [String:Any]
    }
    private static func boolean(_ raw:Any?)->Bool? {
        guard let number=raw as? NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else {return nil};return number.boolValue
    }
    private static func hostname(_ name:String)->String? {
        guard name.utf8.count<=maximumHostBytes,name.utf8.allSatisfy({$0<asciiLimit}) else {return nil}
        let host=name.lowercased(),labels=host.split(separator:".",omittingEmptySubsequences:false)
        guard labels.count>=minimumTailnetLabels,host.hasSuffix(".ts.net") else {return nil}
        for label in labels {
            guard !label.isEmpty,label.utf8.count<=maximumLabelBytes,label.first != "-",label.last != "-",
                  label.utf8.allSatisfy({(UInt8(ascii:"a")...UInt8(ascii:"z")).contains($0) || (UInt8(ascii:"0")...UInt8(ascii:"9")).contains($0) || $0==UInt8(ascii:"-")}) else {return nil}
        }
        return host
    }
    private static func siteAddress(_ site:String)->(Address,UInt16)? {
        let parts=site.split(separator:":",omittingEmptySubsequences:false)
        guard parts.count==2,let host=hostname(String(parts[0])),let port=UInt16(parts[1]),
              String(port)==parts[1],publicPorts.contains(port),
              let url=URL(string:"https://"+host+(port==defaultHTTPSPort ? "":":\(port)")) else {return nil}
        return (Address(url),port)
    }
    private static func read(_ bytes:Data)->Any? {
        guard !bytes.isEmpty,bytes.count<=maximumOutputBytes else {return nil}
        var reader=JSONBoundary(bytes:Array(bytes))
        guard reader.value(depth:0),reader.finished else {return nil}
        return try? JSONSerialization.jsonObject(with:bytes,options:[.fragmentsAllowed])
    }
    // Foundation's object decoder otherwise accepts duplicate keys. This bounded
    // preflight rejects them, including escaped spellings, before object decoding.
    private struct JSONBoundary {
        private enum Mark {
            static let objectOpen:UInt8=123,objectClose:UInt8=125,arrayOpen:UInt8=91,arrayClose:UInt8=93
            static let quote:UInt8=34,escape:UInt8=92,colon:UInt8=58,comma:UInt8=44,space:UInt8=32
            static let whitespace:Set<UInt8>=[9,10,13,space]
            static let valueEnd=whitespace.union([comma,arrayClose,objectClose])
        }
        let bytes:[UInt8]
        private var index=0,values=0
        init(bytes:[UInt8]) {self.bytes=bytes}
        var finished:Bool {mutating get {space();return index==bytes.count}}
        private mutating func space() {while index<bytes.count && Mark.whitespace.contains(bytes[index]) {index += 1}}
        private mutating func take(_ byte:UInt8)->Bool {
            space();guard index<bytes.count,bytes[index]==byte else {return false};index += 1;return true
        }
        private mutating func string()->Range<Int>? {
            space();let start=index;guard index<bytes.count,bytes[index]==Mark.quote else {return nil};index += 1
            var escaped=false
            while index<bytes.count {
                let byte=bytes[index];index += 1
                guard index-start<=maximumStringBytes+2,byte>=Mark.space else {return nil}
                if escaped {escaped=false;continue}
                if byte==Mark.escape {escaped=true;continue}
                if byte==Mark.quote {return start..<index}
            }
            return nil
        }
        mutating func value(depth:Int)->Bool {
            space();values += 1
            guard depth<=maximumDepth,values<=maximumValues,index<bytes.count else {return false}
            switch bytes[index] {
            case Mark.objectOpen:
                index += 1;if take(Mark.objectClose) {return true};var keys=Set<String>()
                while true {
                    guard let range=string(),range.count<=maximumKeyBytes+2,
                          let key=(try? JSONSerialization.jsonObject(with:Data(bytes[range]),options:[.fragmentsAllowed])) as? String,
                          key.utf8.count<=maximumKeyBytes,keys.insert(key).inserted,take(Mark.colon),value(depth:depth+1) else {return false}
                    if take(Mark.objectClose) {return true};guard take(Mark.comma) else {return false}
                }
            case Mark.arrayOpen:
                index += 1;if take(Mark.arrayClose) {return true}
                while true {guard value(depth:depth+1) else {return false};if take(Mark.arrayClose) {return true};guard take(Mark.comma) else {return false}}
            case Mark.quote:return string() != nil
            default:
                let start=index
                while index<bytes.count && !Mark.valueEnd.contains(bytes[index]) {index += 1}
                return index>start && index-start<=maximumPrimitiveBytes
            }
        }
    }
}
