import Foundation

enum WebSocketPackets {
    static let maximumFrameBytes=8192,maximumMessageBytes=8192,maximumReadBytes=16384,maximumFragments=64
    private static let maximumControlBytes=125,maximumHeaderBytes=14
    private static let clientExtensionCloseCode:UInt16=1010
    enum Kind:UInt8 {case continuation=0,text=1,binary=2,close=8,ping=9,pong=10}
    enum Event:Equatable {case pending,text(Data),binary(Data),ping(Data),pong(Data),close(Data),protocolError,limit,cancelled,ended,closed}
    struct Receipt:Equatable {let event:Event;let consumedBytes:Int}

    final class CloseResponse {
        static let maximumBytes=127
        private let lock=NSLock();private var bytes:Data?
        fileprivate init(_ bytes:Data) {self.bytes=bytes}
        func takeBytes()->Data? {lock.lock();defer {lock.unlock()};let result=bytes;bytes=nil;return result}
    }
    // A single transport executor owns this parser; it emits one event and leaves subsequent bytes with its owner.
    final class Reader {
        private let fromClient:Bool
        private var header=[UInt8](),payload=[UInt8](),message=Data()
        private var length:Int?,requiredHeader=2,kind:Kind?,final=false
        private var fragmentKind:Kind?,fragments=0
        private var retired=false,cancelled=false
        init(fromClient:Bool=true) {self.fromClient=fromClient}
        private var closeResponse:CloseResponse?
        private let responseOwnerLock=NSLock();private var responseOwner:UUID?
        func bindCloseResponses(to owner:UUID)->Bool {
            responseOwnerLock.lock();defer {responseOwnerLock.unlock()}
            guard responseOwner==nil || responseOwner==owner else {return false};responseOwner=owner;return true
        }
        func takeCloseResponse()->CloseResponse? {let result=closeResponse;closeResponse=nil;return result}
        var bufferedBytes:Int {header.count+payload.count+message.count}
        func cancel() {
            guard !retired else {return}
            cancelled=true;retired=true;clear()
        }
        func endOfInput()->Event {
            guard !retired else {return cancelled ? .cancelled:.closed}
            let truncated = !header.isEmpty || fragmentKind != nil
            retired=true;clear()
            return truncated ? .protocolError:.ended
        }
        func feed(_ input:Data)->Receipt {
            guard !retired else {return Receipt(event:cancelled ? .cancelled:.closed,consumedBytes:0)}
            guard input.count<=maximumReadBytes else {return fail(.limit,consumed:0)}
            var consumed=0
            for byte in input {
                consumed += 1
                if length==nil || header.count<requiredHeader {
                    guard header.count<maximumHeaderBytes else {return fail(.protocolError,consumed:consumed)}
                    header.append(byte)
                    if let error=readHeader() {return fail(error,consumed:consumed)}
                    if header.count==requiredHeader,length==0 {
                        let event=completeFrame()
                        if event != .pending {return deliver(event,consumed:consumed)}
                    }
                } else {
                    guard let length,payload.count<length else {return fail(.protocolError,consumed:consumed)}
                    let unmasked=fromClient ? byte^header[requiredHeader-4+payload.count%4]:byte
                    payload.append(unmasked)
                    if payload.count==length {
                        let event=completeFrame()
                        if event != .pending {return deliver(event,consumed:consumed)}
                    }
                }
            }
            return Receipt(event:.pending,consumedBytes:consumed)
        }
        private func readHeader()->Event? {
            if header.count==2 {
                guard header[0]&0x70==0,let value=Kind(rawValue:header[0]&15),((header[1]&0x80) != 0)==fromClient else {return .protocolError}
                kind=value;final=header[0]&0x80 != 0
                let marker=header[1]&0x7f
                if value.rawValue>=8 {
                    guard final,marker<=maximumControlBytes else {return .protocolError}
                } else {
                    guard (value == .continuation)==(fragmentKind != nil) else {return .protocolError}
                }
                requiredHeader=2+(marker==126 ? 2:marker==127 ? 8:0)+(fromClient ? 4:0)
                if marker<126 {return admitLength(UInt64(marker))}
            }
            if header.count>=2 {
                let marker=header[1]&0x7f
                if marker==127,header.count==3,header[2]&0x80 != 0 {return .protocolError}
                if length==nil,((marker==126 && header.count==4)||(marker==127 && header.count==10)) {
                    var value:UInt64=0
                    for byte in header.dropFirst(2) {value=(value<<8)|UInt64(byte)}
                    guard (marker==126 && value>=126)||(marker==127 && value>=65536) else {return .protocolError}
                    return admitLength(value)
                }
            }
            return nil
        }
        private func admitLength(_ value:UInt64)->Event? {
            guard value<=maximumFrameBytes else {return .limit}
            guard let kind else {return .protocolError}
            if kind.rawValue<8 {
                guard value<=UInt64(maximumMessageBytes-message.count),fragments<maximumFragments else {return .limit}
                fragments += 1
            }
            length=Int(value)
            return nil
        }
        private func completeFrame()->Event {
            guard let kind else {return .protocolError}
            let data=Data(payload)
            defer {resetFrame()}
            switch kind {
            case .ping:return .ping(data)
            case .pong:return .pong(data)
            case .close:
                guard validClose(data,fromClient:fromClient) else {return .protocolError}
                return .close(data)
            case .text,.binary,.continuation:
                if kind != .continuation {fragmentKind=kind}
                message.append(data)
                guard final else {return .pending}
                let result=message,original=fragmentKind
                message.removeAll(keepingCapacity:false);fragmentKind=nil;fragments=0
                if original == .text {
                    guard String(data:result,encoding:.utf8) != nil else {return .protocolError}
                    return .text(result)
                }
                return .binary(result)
            }
        }
        private func deliver(_ event:Event,consumed:Int)->Receipt {
            switch event {
            case .protocolError,.limit:return fail(event,consumed:consumed)
            case .close(let payload):
                if fromClient {
                    let code=payload.count>=2 ? (UInt16(payload[payload.startIndex])<<8)|UInt16(payload[payload.index(after:payload.startIndex)]):nil
                    let body=code==clientExtensionCloseCode ? Data():payload
                    if let frame=serverFrame(kind:.close,payload:body) {closeResponse=CloseResponse(frame)}
                }
                retired=true;clear()
            default:break
            }
            return Receipt(event:event,consumedBytes:consumed)
        }
        private func fail(_ event:Event,consumed:Int)->Receipt {
            retired=true;clear();return Receipt(event:event,consumedBytes:consumed)
        }
        private func resetFrame() {
            header.removeAll(keepingCapacity:false);payload.removeAll(keepingCapacity:false)
            length=nil;requiredHeader=2;kind=nil;final=false
        }
        private func clear() {resetFrame();message.removeAll(keepingCapacity:false);fragmentKind=nil;fragments=0}
    }
    static func serverFrame(kind:Kind,payload:Data)->Data? {
        guard kind != .continuation,payload.count<=maximumFrameBytes else {return nil}
        if kind.rawValue>=8, payload.count>maximumControlBytes {return nil}
        if kind == .text,String(data:payload,encoding:.utf8)==nil {return nil}
        if kind == .close,!validClose(payload,fromClient:false) {return nil}
        var bytes=Data([0x80|kind.rawValue])
        if payload.count<126 {bytes.append(UInt8(payload.count))} else {bytes.append(contentsOf:[126,UInt8(payload.count>>8),UInt8(payload.count&255)])}
        bytes.append(payload)
        return bytes
    }
    private static func validClose(_ data:Data,fromClient:Bool)->Bool {
        guard !data.isEmpty else {return true}
        guard data.count>=2,data.count<=maximumControlBytes else {return false}
        let first=data.startIndex,second=data.index(after:first)
        let code=(UInt16(data[first])<<8)|UInt16(data[second])
        // Known standard codes from the IANA registry; extensions are not negotiated here.
        let standard=[1000,1001,1002,1003,1007,1008,1009,1010,1011,1012,1013,1014].contains(Int(code))
        guard standard || (3000...4999).contains(code),fromClient || code != clientExtensionCloseCode else {return false}
        return String(data:data.dropFirst(2),encoding:.utf8) != nil
    }
}
