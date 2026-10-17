// STAND-IN for Apple's UniformTypeIdentifiers: declarations only, for the types the app names.
public struct UTType: Hashable, Sendable {
    public init?(filenameExtension: String) {}
    public init?(_ identifier: String) {}
    public let identifier: String = ""
    public static let wav = UTType("com.microsoft.waveform-audio")!
    public static let audio = UTType("public.audio")!
    public static let folder = UTType("public.folder")!
    public static let json = UTType("public.json")!
    public static let plainText = UTType("public.plain-text")!
    public static let data = UTType("public.data")!
    public static let mp3 = UTType("public.mp3")!
    public static let item = UTType("public.item")!
}