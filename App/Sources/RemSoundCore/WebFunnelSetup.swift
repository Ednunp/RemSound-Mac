import Foundation

// Native setup ownership starts with the first acquired resource. Every close
// or destroy is attempted once: an ambiguous result cannot release the credit.
final class WebFunnelSetup {
    static let maximumResources=12
    private struct Entry {let identity:Int,close:()->Bool;var attempted=false,closed=false}
    private var entries=[Entry]()
    var count:Int {entries.count}
    var complete:Bool {entries.allSatisfy(\.closed)}
    var remaining:Int {Self.maximumResources-entries.count}
    @discardableResult func own(_ identity:Int,close:@escaping()->Bool)->Bool {
        guard remaining>0,!entries.contains(where:{$0.identity==identity && !$0.closed}) else {return false}
        entries.append(Entry(identity:identity,close:close));return true
    }
    @discardableResult func close(_ identity:Int)->Bool {
        guard let index=entries.lastIndex(where:{$0.identity==identity}) else {return false}
        if entries[index].attempted {return entries[index].closed}
        entries[index].attempted=true
        let closed=entries[index].close();entries[index].closed=closed;return closed
    }
    @discardableResult func retire(except:Set<Int> = [])->Bool {
        for entry in entries where !except.contains(entry.identity) {_ = close(entry.identity)}
        return entries.allSatisfy{except.contains($0.identity) || $0.closed}
    }
}
