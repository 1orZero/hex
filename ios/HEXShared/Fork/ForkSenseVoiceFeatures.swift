import Accelerate
import FluidAudio
import Foundation

/// SenseVoice's encoder input: 80 Kaldi log-mel bands per 10 ms frame, 7 frames stacked every
/// 6th (LFR), normalised with FunASR's CMVN, 560 values per row. It's the math of FluidAudio's
/// `SenseVoicePreprocessor` model, done here because on a Mac (macOS 27.2) that model's CPU
/// convolution returns different features on every call once audio passes about 4.5 s, and
/// SenseVoice then reads whole stretches as "The." or nothing.
enum ForkSenseVoiceFeatures {
    static let width = 560
    private static let frameLength = 400
    private static let frameShift = 160
    private static let fftLength = 512
    private static let bins = 257
    private static let bands = 80
    private static let stacked = 7
    private static let step = 6
    private static let preEmphasis: Float = 0.97

    /// The LFR rows for 16 kHz samples in [-1, 1], at least `frameLength` of them.
    static func rows(_ samples: [Float]) -> (values: [Float], count: Int) {
        let frames = (samples.count - frameLength) / frameShift + 1
        let logMel = logMel(samples, frames: frames)
        let count = (frames + 3) / step + 1
        var values = [Float](repeating: 0, count: count * width)
        for row in 0..<count {
            for slot in 0..<stacked {
                let frame = min(max(row * step + slot - 3, 0), frames - 1)
                for band in 0..<bands {
                    values[row * width + slot * bands + band] = (logMel[frame * bands + band] + negativeMean[band]) * inverseDeviation[band]
                }
            }
        }
        return (values, count)
    }

    private static func logMel(_ samples: [Float], frames: Int) -> [Float] {
        let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftLength), .FORWARD)!
        defer { vDSP_DFT_DestroySetup(setup) }
        var frame = [Float](repeating: 0, count: frameLength)
        var even = [Float](repeating: 0, count: fftLength / 2)
        var odd = [Float](repeating: 0, count: fftLength / 2)
        var real = [Float](repeating: 0, count: fftLength / 2)
        var imaginary = [Float](repeating: 0, count: fftLength / 2)
        var power = [Float](repeating: 0, count: bins)
        var output = [Float](repeating: 0, count: frames * bands)
        for index in 0..<frames {
            let start = index * frameShift
            for offset in 0..<frameLength { frame[offset] = samples[start + offset] * SenseVoiceConfig.waveformScale }
            let mean = vDSP.mean(frame)
            var previous = frame[0] - mean
            for offset in 0..<frameLength {
                let centred = frame[offset] - mean
                frame[offset] = (centred - preEmphasis * previous) * window[offset]
                previous = centred
            }
            for pair in 0..<(fftLength / 2) {
                even[pair] = 2 * pair < frameLength ? frame[2 * pair] : 0
                odd[pair] = 2 * pair + 1 < frameLength ? frame[2 * pair + 1] : 0
            }
            vDSP_DFT_Execute(setup, even, odd, &real, &imaginary)
            // vDSP's real DFT returns twice each coefficient, with the Nyquist bin in imaginary[0].
            power[0] = real[0] * real[0] / 4
            power[bins - 1] = imaginary[0] * imaginary[0] / 4
            for bin in 1..<(bins - 1) { power[bin] = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) / 4 }
            output.withUnsafeMutableBufferPointer { output in
                vDSP_mmul(power, 1, melFilters, 1, output.baseAddress! + index * bands, 1, 1, vDSP_Length(bands), vDSP_Length(bins))
            }
        }
        return output.map { log(max($0, Float.ulpOfOne)) }
    }

    private static let window = (0..<frameLength).map { 0.54 - 0.46 * cos(2 * Float.pi * Float($0) / Float(frameLength - 1)) }

    /// Kaldi's triangular mel filters from 20 Hz to 8 kHz, `bins` × `bands`, row-major.
    private static let melFilters: [Float] = {
        func mel(_ frequency: Double) -> Double { 1127 * log(1 + frequency / 700) }
        let low = mel(20)
        let delta = (mel(8_000) - low) / Double(bands + 1)
        var filters = [Float](repeating: 0, count: bins * bands)
        for band in 0..<bands {
            let left = low + Double(band) * delta
            for bin in 0..<(bins - 1) {
                let point = mel(Double(bin) * 16_000 / Double(fftLength))
                let weight = min((point - left) / delta, (left + 2 * delta - point) / delta)
                filters[bin * bands + band] = Float(max(0, weight))
            }
        }
        return filters
    }()

    /// FunASR's `am.mvn` for SenseVoice-Small: minus the mean and one over the deviation of each
    /// band, the same for all seven stacked frames.
    private static let negativeMean: [Float] = [
        -8.31187916, -8.60091209, -9.6159277, -10.4359503, -11.2129202, -11.8833303, -12.3624296, -12.6370602,
        -12.8817997, -12.8306599, -12.8910303, -12.9566603, -13.1976299, -13.4059801, -13.4911299, -13.5545998,
        -13.5563898, -13.5191498, -13.6828403, -13.5328903, -13.4210701, -13.6551905, -13.5071297, -13.7525101,
        -13.7671499, -13.8740797, -13.7310896, -13.7041197, -13.56073, -13.5348797, -13.5489502, -13.5622797,
        -13.59408, -13.62047, -13.6419802, -13.6610899, -13.6266899, -13.5829697, -13.5738697, -13.4738998,
        -13.5306301, -13.4834805, -13.6104698, -13.6471596, -13.7154598, -13.7918396, -13.9061403, -14.0309801,
        -14.1820498, -14.3588104, -14.48419, -14.6017199, -14.7059097, -14.8336201, -14.9212198, -15.0062199,
        -15.0512199, -15.0311899, -14.9902802, -14.9230204, -14.8692703, -14.82691, -14.7972002, -14.7690897,
        -14.7135601, -14.6127701, -14.5169601, -14.4225197, -14.3640499, -14.3045101, -14.2316103, -14.1985102,
        -14.1663303, -14.1564903, -14.1050396, -13.9951801, -13.79562, -13.3996, -12.7767, -11.71208,
    ]
    private static let inverseDeviation: [Float] = [
        0.155774996, 0.154484004, 0.152737901, 0.1518718, 0.150602803, 0.148925602, 0.147066996, 0.1447061,
        0.143630698, 0.144356802, 0.145184904, 0.145515695, 0.145282105, 0.144571707, 0.143919498, 0.143586695,
        0.143601805, 0.143878102, 0.144208595, 0.144884393, 0.145475596, 0.145662993, 0.146267995, 0.146738604,
        0.147272393, 0.147663996, 0.148091301, 0.148373902, 0.148884103, 0.149363607, 0.149708793, 0.1500379,
        0.150291607, 0.150538906, 0.150678694, 0.150710195, 0.150599197, 0.150544494, 0.150593802, 0.150813296,
        0.150956899, 0.151239604, 0.151462495, 0.151619494, 0.151615605, 0.151556104, 0.151496604, 0.151397601,
        0.151261196, 0.151076004, 0.151059598, 0.151043102, 0.151077002, 0.151116803, 0.151191697, 0.151023,
        0.150804505, 0.150588498, 0.150349304, 0.150237307, 0.150172606, 0.150076196, 0.150006503, 0.149978206,
        0.150057003, 0.150265798, 0.150469005, 0.150533497, 0.1505505, 0.150532797, 0.150427505, 0.150243804,
        0.149967402, 0.149711803, 0.149466097, 0.149310201, 0.149368107, 0.149550095, 0.149973795, 0.150965393,
    ]
}
