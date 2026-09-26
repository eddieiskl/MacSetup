import Foundation

/// What CPU architecture(s) an executable actually contains.
///
/// Determined by reading the Mach-O (or fat/universal) header directly —
/// never guessed from an app's name or catalogue entry. `unknown` is returned
/// whenever the file can't be read or doesn't look like a Mach-O binary at
/// all; it is never upgraded to a guess.
public enum BinaryArchitecture: String, Codable {
    case appleSilicon
    case intel
    case universal
    case unknown
}

public enum BinaryArchitectureDetector {

    // Fat (universal) binaries store their header big-endian on disk,
    // regardless of the reading host's own endianness.
    private static let fatMagic: UInt32 = 0xcafebabe
    private static let fatMagic64: UInt32 = 0xcafebabf

    // Thin Mach-O magic is defined to match the *reading* host's endianness
    // when the file and host agree — true for every architecture macOS runs
    // today (x86_64, arm64 are both little-endian), so no byte-swap is needed
    // once this constant matches.
    private static let machMagic64: UInt32 = 0xfeedfacf
    private static let machMagic32: UInt32 = 0xfeedface

    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000C

    /// Inspects the actual executable inside an app bundle, rather than the
    /// bundle's Info.plist or name.
    public static func detectBundle(at bundlePath: String) -> BinaryArchitecture {
        guard let exe = executablePath(inBundleAt: bundlePath) else { return .unknown }
        return detect(executableAt: exe)
    }

    /// Finds the bundle's main executable via its Info.plist, falling back to
    /// the conventional `Contents/MacOS/<bundle name>` layout.
    public static func executablePath(inBundleAt bundlePath: String) -> String? {
        let plistPath = bundlePath + "/Contents/Info.plist"
        if let d = NSDictionary(contentsOfFile: plistPath),
           let name = d["CFBundleExecutable"] as? String {
            let candidate = bundlePath + "/Contents/MacOS/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Fall back to whatever's in Contents/MacOS, when the plist is missing
        // or names something that isn't actually there.
        let macOSDir = bundlePath + "/Contents/MacOS"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: macOSDir),
              let first = entries.first else { return nil }
        return macOSDir + "/" + first
    }

    public static func detect(executableAt path: String) -> BinaryArchitecture {
        guard let fh = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? fh.close() }
        guard let header = try? fh.read(upToCount: 4096), header.count >= 8 else { return .unknown }

        let magicBE = readUInt32(header, at: 0, bigEndian: true)
        if magicBE == fatMagic || magicBE == fatMagic64 {
            return detectFat(header, is64: magicBE == fatMagic64)
        }

        let magicNative = readUInt32(header, at: 0, bigEndian: false)
        guard magicNative == machMagic64 || magicNative == machMagic32 else { return .unknown }
        let cpuType = readUInt32(header, at: 4, bigEndian: false)
        return architecture(forCPUType: cpuType)
    }

    private static func detectFat(_ header: Data, is64: Bool) -> BinaryArchitecture {
        let count = readUInt32(header, at: 4, bigEndian: true)
        guard count > 0, count <= 10 else { return .unknown }
        let entrySize = is64 ? 32 : 20
        var found: Set<BinaryArchitecture> = []

        for i in 0..<Int(count) {
            let offset = 8 + i * entrySize
            guard offset + 8 <= header.count else { break }
            let cpuType = readUInt32(header, at: offset, bigEndian: true)
            switch architecture(forCPUType: cpuType) {
            case .appleSilicon: found.insert(.appleSilicon)
            case .intel: found.insert(.intel)
            default: break
            }
        }

        if found.contains(.appleSilicon) && found.contains(.intel) { return .universal }
        if found.contains(.appleSilicon) { return .appleSilicon }
        if found.contains(.intel) { return .intel }
        return .unknown
    }

    private static func architecture(forCPUType cpuType: UInt32) -> BinaryArchitecture {
        switch cpuType {
        case cpuTypeARM64: return .appleSilicon
        case cpuTypeX86_64: return .intel
        default: return .unknown
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let bytes = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4))
        let value = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        return bigEndian ? value.bigEndian : value.littleEndian
    }
}
