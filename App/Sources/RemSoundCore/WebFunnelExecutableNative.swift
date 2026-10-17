import Darwin
import Foundation
import Security

extension WebFunnelExecutable {
    static func native(isolated:Bool,permitted:@escaping()->Bool)->WebFunnelQuery.Launch {
        launch(isolated:isolated,permitted:permitted,inspect:{root,gate in
            inspectNative(root,isolated:isolated,permitted:gate)
        },missing:{
            var info=stat()
            return Darwin.lstat(bundle.path,&info) != 0 && errno==ENOENT
        },factory:{proof,plan,sink,gate in
            WebFunnelProcess.approvedNative(isolated:isolated,permitted:gate,proof:proof)(plan,sink)
        })
    }
    // Omit kSecCSAllowNetworkAccess: trust/resource checking must stay offline.
    static var validationFlags:SecCSFlags {
        SecCSFlags(rawValue:kSecCSCheckAllArchitectures|kSecCSCheckNestedCode|kSecCSStrictValidate|kSecCSRestrictSymlinks|kSecCSSingleThreaded)
    }
    // Static observations feed the suspended-child validator. They cannot
    // replace its check of the actual launched image.
    static func inspectNative(_ root:URL,isolated:Bool,permitted:()->Bool)->Inspection? {
        guard !isolated,permitted(),root.isFileURL,root.host==nil || root.host=="localhost",root.user==nil,root.password==nil,
              root.port==nil,root.query==nil,root.fragment==nil,root.path.utf8.count<=maximumPathBytes,!root.path.utf8.contains(0),
              root.path.hasPrefix("/"),root.lastPathComponent=="Tailscale.app",root.standardizedFileURL.path==root.path,
              permitted(),root.resolvingSymlinksInPath().path==root.path else {return nil}
        let contents=root.appendingPathComponent("Contents",isDirectory:true),mac=contents.appendingPathComponent("MacOS",isDirectory:true)
        let info=contents.appendingPathComponent("Info.plist"),executable=mac.appendingPathComponent("Tailscale")
        let paths=[root,contents,mac,info,executable]
        let metadataIndex=3,executableIndex=4
        func snapshot()->[Stamp]? {
            var result=[Stamp]()
            for (index,path) in paths.enumerated() {
                guard permitted(),let stamp=nativeStamp(path,directory:index<metadataIndex),!stamp.symlink,!stamp.writableByOthers else {return nil}
                result.append(stamp)
            }
            guard result[metadataIndex].size>0,result[metadataIndex].size<=UInt64(maximumMetadataBytes),
                  result[executableIndex].size>0,result[executableIndex].size<=maximumExecutableBytes,result[executableIndex].executable else {return nil}
            return result
        }
        guard let before=snapshot(),permitted() else {return nil}
        var code:SecStaticCode?,requirement:SecRequirement?
        guard SecStaticCodeCreateWithPath(root as CFURL,[],&code)==errSecSuccess,let code,permitted(),
              SecRequirementCreateWithString("anchor apple generic" as CFString,[],&requirement)==errSecSuccess,let requirement,
              permitted(),SecStaticCodeCheckValidity(code,validationFlags,requirement)==errSecSuccess,permitted() else {return nil}
        var raw:CFDictionary?
        guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&raw)==errSecSuccess,
              let fields=raw as? [String:Any],permitted(),
              let identifier=fields[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier=fields[kSecCodeInfoTeamIdentifier as String] as? String,
              let digest=fields[kSecCodeInfoUnique as String] as? Data,
              let signedInfo=fields[kSecCodeInfoPList as String] as? [String:Any],
              let bundleIdentifier=signedInfo["CFBundleIdentifier"] as? String,bundleIdentifier==identifier,
              let name=signedInfo["CFBundleExecutable"] as? String,
              let version=signedInfo["CFBundleShortVersionString"] as? String,
              let main=fields[kSecCodeInfoMainExecutable as String] as? URL,main==executable,
              let after=snapshot(),before==after,permitted() else {return nil}
        let inspection=Inspection(identifier:identifier,teamIdentifier:teamIdentifier,version:version,executableName:name,digest:digest,
            before:before[executableIndex],after:after[executableIndex],metadataBytes:Int(before[metadataIndex].size),signatureValid:true,resourcesValid:true,offline:true)
        guard approve(inspection) != nil else {return nil};return inspection
    }
    private static func nativeStamp(_ path:URL,directory:Bool)->Stamp? {
        var value=stat()
        guard path.path.withCString({lstat($0,&value)})==0,value.st_size>=0,
              let device=UInt64(exactly:value.st_dev),let modified=nanoseconds(value.st_mtimespec),let changed=nanoseconds(value.st_ctimespec) else {return nil}
        let kind=value.st_mode & mode_t(S_IFMT)
        guard kind==mode_t(directory ? S_IFDIR:S_IFREG) else {return nil}
        return Stamp(device:device,inode:value.st_ino,size:UInt64(value.st_size),modified:modified,changed:changed,
            regular:kind==mode_t(S_IFREG),executable:(value.st_mode & mode_t(S_IXUSR|S_IXGRP|S_IXOTH)) != 0,
            symlink:kind==mode_t(S_IFLNK),writableByOthers:(value.st_mode & mode_t(S_IWGRP|S_IWOTH)) != 0)
    }
    private static func nanoseconds(_ value:timespec)->UInt64? {
        guard let seconds=UInt64(exactly:value.tv_sec),let fraction=UInt64(exactly:value.tv_nsec),fraction<1_000_000_000,
              seconds<=(UInt64.max-fraction)/1_000_000_000 else {return nil}
        return seconds*1_000_000_000+fraction
    }
}
