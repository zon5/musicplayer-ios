import Foundation
import AVFoundation

/// 给走 AVPlayer 的歌曲（系统库 ipod-library://）挂音频处理 tap，把 PCM 喂给频谱。
/// 这些回调是 C 函数指针，不能捕获上下文，统一通过 SpectrumStore.shared 取单例。
extension SpectrumStore {
    /// 为 asset 生成一个带频谱 tap 的 audioMix，赋给 AVPlayerItem.audioMix 即可。
    func audioMix(for asset: AVAsset) -> AVAudioMix? {
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
        var cb = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: nil,
            init: spectrumTapInit,
            finalize: spectrumTapFinalize,
            prepare: spectrumTapPrepare,
            unprepare: spectrumTapUnprepare,
            process: spectrumTapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationType_Preprocessing, &tap
        )
        guard status == noErr, let tap = tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

private func spectrumTapInit(
    _ tap: UnsafeMutablePointer<MTAudioProcessingTap>?,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ storage: UnsafeMutablePointer<Unmanaged<AnyObject>>?
) {
    storage?.pointee = Unmanaged.passUnretained(SpectrumStore.shared)
}

private func spectrumTapFinalize(_ tap: UnsafeMutablePointer<MTAudioProcessingTap>?) {}

private func spectrumTapPrepare(
    _ tap: UnsafeMutablePointer<MTAudioProcessingTap>?,
    _ maxFrames: CMItemCount,
    _ processingFormat: UnsafeMutablePointer<AudioStreamBasicDescription>?
) {}

private func spectrumTapUnprepare(_ tap: UnsafeMutablePointer<MTAudioProcessingTap>?) {}

private func spectrumTapProcess(
    _ tap: UnsafeMutablePointer<MTAudioProcessingTap>?,
    _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>?,
    _ flagsInOut: MTAudioProcessingTapFlags,
    _ timeRangeOut: UnsafeMutablePointer<CMTimeRange>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>,
    _ numberFramesOut: UnsafeMutablePointer<CMItemCount>
) {
    let frames = numberFramesOut.pointee
    guard frames > 0, let tap = tap else { return }
    var src: UnsafeMutablePointer<AudioBufferList>?
    var flags = MTAudioProcessingTapFlags()
    var range = CMTimeRange()
    var got: CMItemCount = 0
    let st = MTAudioProcessingTapGetSourceAudio(tap, frames, &src, &flags, &range, &got)
    guard st == noErr, let bl = src, got > 0 else { return }

    let abl = UnsafeMutableAudioBufferListPointer(bl)
    let channels = abl.count
    guard channels > 0 else { return }
    let count = Int(got)
    var mono = [Float](repeating: 0, count: count)
    for c in 0..<channels {
        guard let data = abl[c].mData else { continue }
        let ptr = data.assumingMemoryBound(to: Float.self)
        for i in 0..<count { mono[i] += ptr[i] / Float(channels) }
    }
    SpectrumStore.shared.feed(mono: mono)
}
