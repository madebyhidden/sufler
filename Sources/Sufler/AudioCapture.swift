import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Приводит любой входной формат к 16 кГц моно Float32 — то, что ждёт Whisper.
final class Resampler {
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if inFormat != buffer.format {
            inFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter, buffer.frameLength > 0 else { return [] }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

/// Микрофон.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let resampler = Resampler()
    var onSamples: (([Float]) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw err("Микрофон недоступен") }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let s = self.resampler.convert(buf)
            if !s.isEmpty { self.onSamples?(s) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Системный звук (всё, что играют другие приложения) через Core Audio process tap.
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let resampler = Resampler()
    private let queue = DispatchQueue(label: "sufler.systemaudio", qos: .userInitiated)
    var onSamples: (([Float]) -> Void)?

    func start() throws {
        // Свой процесс исключаем, чтобы не записывать собственные звуки
        var exclude: [AudioObjectID] = []
        if let own = Self.processObject(pid: getpid()) { exclude.append(own) }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "Sufler"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw err("Не удалось подключиться к системному звуку (\(st)). Проверьте разрешение на запись звука системы.") }

        let outUID = try Self.defaultOutputUID()
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sufler Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard st == noErr else { stop(); throw err("Не удалось создать устройство записи (\(st))") }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        st = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard st == noErr, let format = AVAudioFormat(streamDescription: &asbd) else { stop(); throw err("Неизвестный формат системного звука") }

        tapFormat = format
        declared = asbd
        windowStart = 0
        windowFrames = 0
        lastMeasured = 0
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] _, inData, _, _, _ in
            guard let self else { return }
            self.measureRate(inData)
            guard let buf = AVAudioPCMBuffer(pcmFormat: self.tapFormat, bufferListNoCopy: inData, deallocator: nil) else { return }
            let s = self.resampler.convert(buf)
            if !s.isEmpty { self.onSamples?(s) }
        }
        guard st == noErr else { stop(); throw err("Не удалось начать чтение системного звука (\(st))") }
        st = AudioDeviceStart(aggID, procID)
        guard st == noErr else { stop(); throw err("Не удалось запустить запись системного звука (\(st))") }
    }

    // Заявленной частоте звука верить нельзя: устройство вывода может сменить её посреди звонка
    // (подключили наушники, приложение для звонков переключило режим), и тогда запись звучит
    // быстрее и выше или медленнее и ниже. Поэтому частоту меряем сами — по тому, сколько звука
    // реально приходит в секунду, — и при расхождении переходим на измеренную.
    private var tapFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var declared = AudioStreamBasicDescription()
    private var windowStart: UInt64 = 0
    private var windowFrames = 0
    private var lastMeasured: Double = 0
    private static let standardRates: [Double] = [8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000]

    private func measureRate(_ data: UnsafePointer<AudioBufferList>) {
        let bytesPerFrame = Int(declared.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let now = mach_absolute_time()
        if windowStart == 0 { windowStart = now; windowFrames = 0; return }
        windowFrames += Int(data.pointee.mBuffers.mDataByteSize) / bytesPerFrame
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let seconds = Double(now - windowStart) * Double(tb.numer) / Double(tb.denom) / 1e9
        guard seconds >= 3 else { return }
        let rate = Double(windowFrames) / seconds
        windowStart = now
        windowFrames = 0
        // Берём ближайшую стандартную частоту и только если замер к ней близок (иначе это был простой, а не смена частоты)
        guard let snapped = Self.standardRates.min(by: { abs($0 - rate) < abs($1 - rate) }), abs(snapped - rate) / snapped < 0.02 else { lastMeasured = 0; return }
        // Меняем только после двух одинаковых замеров подряд
        defer { lastMeasured = snapped }
        guard snapped == lastMeasured, abs(snapped - tapFormat.sampleRate) / snapped > 0.03 else { return }
        var d = declared
        d.mSampleRate = snapped
        if let f = AVAudioFormat(streamDescription: &d) {
            log("системный звук: заявлено \(tapFormat.sampleRate) Гц, на деле \(snapped) Гц — переключаюсь")
            tapFormat = f
        }
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggID, procID)
                AudioDeviceDestroyIOProcID(aggID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputUID() throws -> String {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        guard st == noErr else { throw err("Нет устройства вывода звука") }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        st = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
        guard st == noErr else { throw err("Нет идентификатора устройства вывода") }
        return uid as String
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var p = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
        return (st == noErr && obj != kAudioObjectUnknown) ? obj : nil
    }
}

func err(_ message: String) -> NSError {
    NSError(domain: "Sufler", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
