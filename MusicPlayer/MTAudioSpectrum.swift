import Foundation
import AVFoundation

/// 给走 AVPlayer 的歌曲（系统库 ipod-library://）挂音频处理 tap，把 PCM 喂给频谱。
/// 这些回调是 C 函数指针（@convention(c)），签名必须和 AVFoundation 定义的一致：
///  tap 参数是非 Optional 的 MTAudioProcessingTap，GetSourceAudio 的 bufferList 也是非 Optional。
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
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &cb, MTAudioProcessingTapCreationType.preprocessing, &tap
        )
        guard status == noErr, let unmanaged = tap else { return nil }
        let processor = unmanaged.takeRetainedValue()
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = processor
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

// MARK: - C 回调（签名严格按 Swift 导入后的 AVFoundation 定义）

private func spectrumTapInit(
    _ tap: MTAudioProcessingTap,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ storage: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    storage.pointee = clientInfo
}

private func spectrumTapFinalize(_ tap: MTAudioProcessingTap) {}

private func spectrumTapPrepare(
    _ tap: MTAudioProcessingTap,
    _ maxFrames: Int,
    _ processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {}

private func spectrumTapUnprepare(_ tap: MTAudioProcessingTap) {}

private func spectrumTapProcess(
    _ tap: MTAudioProcessingTap,
    _ numberFrames: Int,
    _ flagsInOut: MTAudioProcessingTapFlags,
    _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    _ numberFramesOut: UnsafeMutablePointer<Int>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    let frames = numberFramesOut.pointee
    guard frames > 0 else { return }
    var src = bufferListInOut.pointee
    var flags = flagsOut.pointee
    var range = CMTimeRange()
    var got: CMItemCount = 0
    withUnsafeMutablePointer(to: &src) { srcPtr in
        let st = MTAudioProcessingTapGetSourceAudio(tap, frames, srcPtr, &flags, &range, &got)
        guard st == noErr, got > 0 else { return }
        let abl = UnsafeMutableAudioBufferListPointer(srcPtr)
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
}
