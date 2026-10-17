import Foundation
import CryptoKit
import Darwin

enum WebHandshake {
    static let maximumHeadBytes=8192,maximumLineBytes=2048,maximumFields=64,maximumReadBytes=16384
    private static let websocketGUID="258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    enum Outcome:Equatable {case pending,page,upgrade(accept:String,host:String,origin:String?),refused,limit,cancelled,closed}
    struct Receipt:Equatable {let outcome:Outcome;let consumedBytes:Int}

    // Own only the bounded head. A transport retains the unconsumed frame bytes and owns its deadline.
    final class Reader {
        private var bytes=[UInt8]()
        private var lineBytes=0
        private var retired=false,cancelled=false
        private(set) var validatedPageHost:String?
        var bufferedBytes:Int {bytes.count}
        func cancel() {
            guard !retired else {return}
            cancelled=true;retired=true;bytes.removeAll(keepingCapacity:false)
        }
        func feed(_ input:Data)->Receipt {
            if retired {return Receipt(outcome:cancelled ? .cancelled:.closed,consumedBytes:0)}
            guard input.count<=maximumReadBytes else {return finish(.limit,consumed:0)}
            var consumed=0
            for byte in input {
                consumed += 1
                guard bytes.count<maximumHeadBytes,lineBytes<maximumLineBytes else {return finish(.limit,consumed:consumed)}
                guard byte==9 || byte==10 || byte==13 || (32...126).contains(byte) else {return finish(.refused,consumed:consumed)}
                if bytes.last==13 && byte != 10 {return finish(.refused,consumed:consumed)}
                if byte==10 && bytes.last != 13 {return finish(.refused,consumed:consumed)}
                bytes.append(byte);lineBytes += 1
                if byte==10 {lineBytes=0}
                if bytes.count>=4 && bytes.suffix(4).elementsEqual([13,10,13,10]) {
                    return finish(parse(),consumed:consumed)
                }
            }
            return Receipt(outcome:.pending,consumedBytes:consumed)
        }
        private func finish(_ outcome:Outcome,consumed:Int)->Receipt {
            retired=true;bytes.removeAll(keepingCapacity:false)
            return Receipt(outcome:outcome,consumedBytes:consumed)
        }
        private func parse()->Outcome {
            let lines=String(decoding:bytes,as:UTF8.self).components(separatedBy:"\r\n")
            guard lines.count>=4,lines.suffix(2).allSatisfy({$0.isEmpty}) else {return .refused}
            let request=lines[0].components(separatedBy:" ")
            guard request.count==3,request[0]=="GET",request[2]=="HTTP/1.1" else {return .refused}
            let fields=lines.dropFirst().dropLast(2)
            guard fields.count<=maximumFields else {return .limit}
            var headers=[String:String]()
            for field in fields {
                guard let colon=field.firstIndex(of:":") else {return .refused}
                let name=String(field[..<colon])
                guard isToken(name) else {return .refused}
                let key=name.lowercased(),value=ows(String(field[field.index(after:colon)...]))
                // Refuse duplicate fields rather than choosing an ambiguous first or last value.
                guard headers[key]==nil else {return .refused}
                headers[key]=value
            }
            guard let host=headers["host"],validAuthority(host),headers["transfer-encoding"]==nil,
                  headers["content-length"]==nil || headers["content-length"]=="0" else {return .refused}
            let path=request[1]
            if path=="/" || path=="/index.html" {
                guard headers["upgrade"]==nil,headers["sec-websocket-key"]==nil else {return .refused}
                validatedPageHost=host
                return .page
            }
            guard path=="/listen",headers["sec-websocket-version"]=="13",
                  let upgrade=tokens(headers["upgrade"]),upgrade.contains("websocket"),
                  let connection=tokens(headers["connection"]),connection.contains("upgrade"),
                  let key=headers["sec-websocket-key"],key.utf8.count==24,
                  let decoded=Data(base64Encoded:key),decoded.count==16,decoded.base64EncodedString()==key else {return .refused}
            guard validOffers(extensions:headers["sec-websocket-extensions"],protocols:headers["sec-websocket-protocol"]) else {return .refused}
            // SHA-1 is mandated for the upgrade token only, never for a credential or audio key.
            let digest=Insecure.SHA1.hash(data:Data((key+websocketGUID).utf8))
            return .upgrade(accept:Data(digest).base64EncodedString(),host:host,origin:headers["origin"])
        }
    }
    private static func ows(_ value:String)->String {value.trimmingCharacters(in:CharacterSet(charactersIn:" \t"))}
    private static func isToken(_ value:String)->Bool {
        !value.isEmpty && value.utf8.allSatisfy {byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }
    private static func tokens(_ value:String?)->[String]? {
        guard let value else {return nil}
        let parts=value.components(separatedBy:",").map(ows)
        guard parts.allSatisfy(isToken) else {return nil}
        return parts.map {$0.lowercased()}
    }
    private static func validOffers(extensions:String?,protocols:String?)->Bool {
        if let protocols {
            let list=protocols.components(separatedBy:",").map(ows)
            guard list.allSatisfy(isToken),Set(list).count==list.count else {return false}
        }
        guard let extensions else {return true}
        for offer in extensions.components(separatedBy:",") {
            let parts=offer.components(separatedBy:";").map(ows)
            guard let name=parts.first,isToken(name) else {return false}
            for parameter in parts.dropFirst() {
                let pair=parameter.components(separatedBy:"=").map(ows)
                guard pair.count<=2,isToken(pair[0]) else {return false}
                guard pair.count==2 else {continue}
                let value=pair[1]
                if isToken(value) {continue}
                guard value.first=="\"",value.last=="\"",value.utf8.count>=2 else {return false}
                var decoded=[UInt8](),escaped=false
                for byte in value.dropFirst().dropLast().utf8 {
                    if escaped {decoded.append(byte);escaped=false}
                    else if byte==92 {escaped=true}
                    else if byte==34 {return false}
                    else {decoded.append(byte)}
                }
                guard !escaped,isToken(String(decoding:decoded,as:UTF8.self)) else {return false}
            }
        }
        return true
    }
    private static func validAuthority(_ value:String)->Bool {
        guard !value.isEmpty,value.utf8.count<=261 else {return false}
        let host:String,port:String?
        if value.first=="[" {
            guard let close=value.firstIndex(of:"]") else {return false}
            let literal=String(value[value.index(after:value.startIndex)..<close])
            var address=in6_addr()
            guard literal.withCString({inet_pton(AF_INET6,$0,&address)})==1 else {return false}
            host=literal
            let tail=String(value[value.index(after:close)...])
            if tail.isEmpty {port=nil} else {
                guard tail.first==":" else {return false}
                port=String(tail.dropFirst())
            }
        } else {
            let parts=value.components(separatedBy:":")
            guard parts.count<=2 else {return false}
            host=parts[0];port=parts.count==2 ? parts[1]:nil
            let name=host.hasSuffix(".") ? String(host.dropLast()):host
            guard !name.isEmpty,name.utf8.count<=253 else {return false}
            for label in name.components(separatedBy:".") {
                guard !label.isEmpty,label.utf8.count<=63,label.first != "-",label.last != "-",
                      label.utf8.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0==45}) else {return false}
            }
        }
        guard !host.isEmpty else {return false}
        if let port {
            guard !port.isEmpty,port.utf8.count<=5,port.utf8.allSatisfy({(48...57).contains($0)}),let number=UInt16(port),number>0 else {return false}
        }
        return true
    }
}
