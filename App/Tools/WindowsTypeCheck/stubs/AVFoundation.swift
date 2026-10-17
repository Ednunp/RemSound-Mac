// STAND-IN for Apple's AVFoundation audio classes (see CoreAudio.swift): declarations only, for type-checking on Windows.
@_exported import AudioToolbox

public typealias AVAudioFrameCount = UInt32
public typealias AVAudioChannelCount = UInt32
public typealias AVAudioNodeBus = Int
public typealias AVAudioFramePosition = Int64

public enum AVAudioCommonFormat: UInt {
    case otherFormat = 0, pcmFormatFloat32 = 1, pcmFormatFloat64 = 2, pcmFormatInt16 = 3, pcmFormatInt32 = 4
}

open class AVAudioFormat: NSObject {
    public init?(standardFormatWithSampleRate sampleRate: Double, channels: AVAudioChannelCount) {}
    public init?(commonFormat format: AVAudioCommonFormat, sampleRate: Double, channels: AVAudioChannelCount, interleaved: Bool) {}
    public init?(settings: [String: Any]) {}
    open var sampleRate: Double { 0 }
    open var channelCount: AVAudioChannelCount { 0 }
    open var commonFormat: AVAudioCommonFormat { .otherFormat }
    open var isInterleaved: Bool { false }
    open var isStandard: Bool { false }
    open var streamDescription: UnsafePointer<AudioStreamBasicDescription> { fatalError() }
    open var settings: [String: Any] { [:] }
}

open class AVAudioBuffer: NSObject {
    open var format: AVAudioFormat { fatalError() }
    open var audioBufferList: UnsafePointer<AudioBufferList> { fatalError() }
    open var mutableAudioBufferList: UnsafeMutablePointer<AudioBufferList> { fatalError() }
}
open class AVAudioPCMBuffer: AVAudioBuffer {
    public init?(pcmFormat format: AVAudioFormat, frameCapacity: AVAudioFrameCount) {}
    open var frameCapacity: AVAudioFrameCount { 0 }
    open var frameLength: AVAudioFrameCount = 0
    open var stride: Int { 0 }
    open var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? { nil }
    open var int16ChannelData: UnsafePointer<UnsafeMutablePointer<Int16>>? { nil }
    open var int32ChannelData: UnsafePointer<UnsafeMutablePointer<Int32>>? { nil }
}

open class AVAudioTime: NSObject { open var audioTimeStamp: AudioTimeStamp { AudioTimeStamp() } }

open class AVAudioNode: NSObject {
    open func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat { fatalError() }
    open func inputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat { fatalError() }
    open func installTap(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount, format: AVAudioFormat?,
                         block tapBlock: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {}
    open func removeTap(onBus bus: AVAudioNodeBus) {}
}
open class AVAudioIONode: AVAudioNode {
    open var presentationLatency: TimeInterval { 0 }
    open var audioUnit: AudioUnit? { nil }
}
open class AVAudioInputNode: AVAudioIONode {}
open class AVAudioOutputNode: AVAudioIONode {}
open class AVAudioMixerNode: AVAudioNode {
    open var outputVolume: Float = 1
}

public typealias AVAudioSourceNodeRenderBlock = (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, AVAudioFrameCount,
    UnsafeMutablePointer<AudioBufferList>) -> OSStatus
open class AVAudioSourceNode: AVAudioNode {
    public init(renderBlock block: @escaping AVAudioSourceNodeRenderBlock) {}
    public init(format: AVAudioFormat, renderBlock block: @escaping AVAudioSourceNodeRenderBlock) {}
}

open class AVAudioEngine: NSObject {
    public override init() {}
    open var inputNode: AVAudioInputNode { fatalError() }
    open var outputNode: AVAudioOutputNode { fatalError() }
    open var mainMixerNode: AVAudioMixerNode { fatalError() }
    open var isRunning: Bool { false }
    open func attach(_ node: AVAudioNode) {}
    open func detach(_ node: AVAudioNode) {}
    open func connect(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?) {}
    open func prepare() {}
    open func start() throws {}
    open func stop() {}
    open func reset() {}
    open func disconnectNodeOutput(_ node: AVAudioNode) {}
    open func disconnectNodeInput(_ node: AVAudioNode) {}
}
extension NSNotification.Name {
    public static let AVAudioEngineConfigurationChange = NSNotification.Name("AVAudioEngineConfigurationChangeNotification")
}

public enum AVAudioConverterInputStatus: Int { case haveData = 0, noDataNow = 1, endOfStream = 2 }
public enum AVAudioConverterOutputStatus: Int { case haveData = 0, inputRanDry = 1, endOfStream = 2, error = 3 }
public typealias AVAudioConverterInputBlock = (AVAudioPacketCount, UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?
public typealias AVAudioPacketCount = UInt32
public typealias NSErrorPointer = UnsafeMutablePointer<NSError?>?   // AutoreleasingUnsafeMutablePointer on a Mac
open class AVAudioConverter: NSObject {
    public init?(from fromFormat: AVAudioFormat, to toFormat: AVAudioFormat) {}
    open func convert(to outputBuffer: AVAudioBuffer, error outError: NSErrorPointer, withInputFrom inputBlock: AVAudioConverterInputBlock) -> AVAudioConverterOutputStatus { .error }
    open func convert(to outputBuffer: AVAudioPCMBuffer, from inputBuffer: AVAudioPCMBuffer) throws {}
    open func reset() {}
    open var sampleRateConverterQuality: Int = 0
}

open class AVAudioFile: NSObject {
    public init(forReading fileURL: URL) throws {}
    public init(forReading fileURL: URL, commonFormat format: AVAudioCommonFormat, interleaved: Bool) throws {}
    public init(forWriting fileURL: URL, settings: [String: Any]) throws {}
    public init(forWriting fileURL: URL, settings: [String: Any], commonFormat format: AVAudioCommonFormat, interleaved: Bool) throws {}
    open func read(into buffer: AVAudioPCMBuffer) throws {}
    open func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws {}
    open func write(from buffer: AVAudioPCMBuffer) throws {}
    open var length: AVAudioFramePosition { 0 }
    open var fileFormat: AVAudioFormat { fatalError() }
    open var processingFormat: AVAudioFormat { fatalError() }
    open var framePosition: AVAudioFramePosition = 0
}

public let AVFormatIDKey = "AVFormatIDKey"
public let AVSampleRateKey = "AVSampleRateKey"
public let AVNumberOfChannelsKey = "AVNumberOfChannelsKey"
public let AVLinearPCMBitDepthKey = "AVLinearPCMBitDepthKey"
public let AVLinearPCMIsFloatKey = "AVLinearPCMIsFloatKey"
public let AVLinearPCMIsBigEndianKey = "AVLinearPCMIsBigEndianKey"
public let AVLinearPCMIsNonInterleaved = "AVLinearPCMIsNonInterleaved"
public let AVEncoderBitRateKey = "AVEncoderBitRateKey"

// The capture device and its permission (AVCaptureDevice), as the app asks for the microphone.
open class AVCaptureDevice: NSObject {
    public enum AuthorizationStatus: Int { case notDetermined = 0, restricted = 1, denied = 2, authorized = 3 }
    open class func authorizationStatus(for mediaType: AVMediaType) -> AuthorizationStatus { .notDetermined }
    open class func requestAccess(for mediaType: AVMediaType, completionHandler handler: @escaping (Bool) -> Void) {}
}
public struct AVMediaType: Hashable, RawRepresentable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let audio = AVMediaType(rawValue: "soun")
}

open class AVAudioPlayer: NSObject {
    public init(contentsOf url: URL) throws {}
    public init(data: Data) throws {}
    @discardableResult open func play() -> Bool { true }
    @discardableResult open func prepareToPlay() -> Bool { true }
    open func stop() {}
    open func pause() {}
    open var volume: Float = 1
    open var isPlaying: Bool { false }
    open var duration: TimeInterval { 0 }
    open var currentTime: TimeInterval = 0
    open var numberOfLoops: Int = 0
    open weak var delegate: AVAudioPlayerDelegate?
}
public protocol AVAudioPlayerDelegate: NSObjectProtocol {}
extension AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {}
    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {}
}
