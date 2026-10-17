import Foundation

// Inspection values are internal observations. A proof is not an atomic OS
// execution guarantee; a native caller must reprove it at its own launch boundary.
enum WebFunnelExecutable {
    static let bundle = URL(fileURLWithPath:"/Applications/Tailscale.app",isDirectory:true)
    static let executable = bundle.appendingPathComponent("Contents/MacOS/Tailscale")
    static let team = "W5364U7YZB", identifiers:Set<String> = ["io.tailscale.ipn.macos","io.tailscale.ipn.macsys"]
    struct Stamp:Equatable,Sendable {
        var device:UInt64,inode:UInt64,size:UInt64,modified:UInt64,changed:UInt64
        var regular:Bool,executable:Bool,symlink:Bool,writableByOthers:Bool
    }
    struct Inspection:Equatable,Sendable {
        var identifier:String,teamIdentifier:String,version:String,executableName:String
        var digest:Data,before:Stamp,after:Stamp,metadataBytes:Int
        var signatureValid:Bool,resourcesValid:Bool,offline:Bool
    }
    struct Proof:Equatable,Sendable {
        fileprivate let inspection:Inspection
        var url:URL {WebFunnelExecutable.executable}
        var runningRequirement:String {
            let hash=inspection.digest.map{String(format:"%02x",$0)}.joined()
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(inspection.teamIdentifier)\" and identifier \"\(inspection.identifier)\" and cdhash H\"\(hash)\""
        }
    }
    typealias Inspect=(URL,@escaping()->Bool)->Inspection?
    typealias Factory=(Proof,WebFunnelQuery.Plan,WebFunnelQuery.Sink,@escaping()->Bool)->WebFunnelQuery.Child?
    static let maximumMetadataBytes=65_536,maximumPathBytes=4096,codeDirectoryHashBytes=20
    static let maximumExecutableBytes:UInt64=512*1024*1024
    private static let maximumVersionBytes=32,supportedMajor:UInt16=1,minimumMinor:UInt16=52
    static func approve(_ value:Inspection)->Proof? {
        guard value.metadataBytes>0,value.metadataBytes<=maximumMetadataBytes,
              value.identifier.utf8.count<=64,value.teamIdentifier.utf8.count<=16,value.executableName.utf8.count<=32,
              identifiers.contains(value.identifier),value.teamIdentifier==team,value.executableName=="Tailscale",
              value.signatureValid,value.resourcesValid,value.offline,value.digest.count==codeDirectoryHashBytes,
              value.before==value.after,value.before.regular,value.before.executable,!value.before.symlink,
              !value.before.writableByOthers,value.before.inode>0,value.before.size>0,value.before.size<=maximumExecutableBytes,
              supportedVersion(value.version) else {return nil}
        return Proof(inspection:value)
    }
    private static func supportedVersion(_ text:String)->Bool {
        guard !text.isEmpty,text.utf8.count<=maximumVersionBytes,
              text.utf8.allSatisfy({$0==46 || (48...57).contains($0)}) else {return false}
        let fields=text.split(separator:".",omittingEmptySubsequences:false)
        guard fields.count==3 else {return false}
        var values=[UInt16]()
        for field in fields {
            guard !field.isEmpty,field.count==1 || field.first != "0",let number=UInt16(field) else {return false}
            values.append(number)
        }
        // The documented Funnel command family changed in 1.52. Unknown major
        // versions need a new compatibility review, not an assumed fallback.
        return values[0]==supportedMajor && values[1]>=minimumMinor
    }
    static func launch(isolated:Bool,permitted:@escaping()->Bool,inspect:@escaping Inspect,missing:@escaping()->Bool={false},factory:@escaping Factory)->WebFunnelQuery.Launch {
        {plan,sink in
            let gate={ !isolated && permitted() && sink.isPermitted }
            guard gate() else {return nil}
            if missing() {if gate() {sink.failed(.notInstalled)};return nil}
            guard gate(),let first=inspect(bundle,gate),gate(),let proof=approve(first),
                  let second=inspect(bundle,gate),gate(),approve(second)==proof else {return nil}
            return factory(proof,plan,sink,gate)
        }
    }
}
