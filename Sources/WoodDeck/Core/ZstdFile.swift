import Foundation
import CZstd

// 读取由多个 zstd 帧顺序追加的文件。DeepSeek Harness 的会话记录就是这种形式，
// 每批写入一个独立帧，因此要按帧解压，最后一帧未写完时停在它之前
enum ZstdFile {
    enum ReadError: Error {
        case open(String)
        case corrupt(String)
    }

    // 从 offset 处的帧边界往后解压，返回解压出的内容与最后一个完整帧之后的位置。
    // 末尾那帧还没写完时不会越过它，下次可以从返回的位置接着读
    static func decompressRange(_ url: URL, from offset: Int) throws -> (data: Data, end: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.open(url.path(percentEncoded: false))
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else {
            throw ReadError.open(url.path(percentEncoded: false))
        }
        guard let compressed = try? handle.readToEnd(), !compressed.isEmpty else { return (Data(), offset) }
        var output = Data()
        var consumed = 0
        try compressed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while consumed < raw.count {
                let remaining = raw.count - consumed
                let pointer = base.advanced(by: consumed)
                let frameSize = ZSTD_findFrameCompressedSize(pointer, remaining)
                guard ZSTD_isError(frameSize) == 0, frameSize > 0, frameSize <= remaining else {
                    // 末尾是一帧还没写完的数据，丢弃即可
                    break
                }
                output.append(try decodeFrame(pointer: pointer, size: frameSize))
                consumed += frameSize
            }
        }
        return (output, offset + consumed)
    }

    static func decompressAll(_ url: URL) throws -> Data {
        try decompressRange(url, from: 0).data
    }

    private static func decodeFrame(pointer: UnsafeRawPointer, size: Int) throws -> Data {
        let contentSize = ZSTD_getFrameContentSize(pointer, size)
        if contentSize != ZSTD_CONTENTSIZE_ERROR && contentSize != ZSTD_CONTENTSIZE_UNKNOWN {
            var frame = Data(count: Int(contentSize))
            let written = frame.withUnsafeMutableBytes { destination -> Int in
                guard let target = destination.baseAddress else { return -1 }
                return ZSTD_decompress(target, Int(contentSize), pointer, size)
            }
            guard written >= 0, ZSTD_isError(written) == 0 else { throw ReadError.corrupt("zstd") }
            frame.removeSubrange(written..<frame.count)
            return frame
        }
        // 帧头没有记录原始大小时，边解压边扩容
        return try decompressStreaming(pointer: pointer, size: size)
    }

    private static func decompressStreaming(pointer: UnsafeRawPointer, size: Int) throws -> Data {
        guard let context = ZSTD_createDCtx() else { throw ReadError.corrupt("zstd") }
        defer { ZSTD_freeDCtx(context) }
        var output = Data()
        var inBuffer = ZSTD_inBuffer(src: pointer, size: size, pos: 0)
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while inBuffer.pos < inBuffer.size {
            let result = chunk.withUnsafeMutableBytes { destination -> Int in
                var outBuffer = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                let value = ZSTD_decompressStream(context, &outBuffer, &inBuffer)
                if ZSTD_isError(value) == 0 {
                    output.append(contentsOf: destination.bindMemory(to: UInt8.self).prefix(outBuffer.pos))
                }
                return value
            }
            if ZSTD_isError(result) != 0 { throw ReadError.corrupt("zstd") }
            if result == 0 { break }
        }
        return output
    }

    static func lines(_ url: URL) throws -> [Data] {
        split(try decompressAll(url))
    }

    // 按换行切分，末尾没有换行的半行不返回
    static func split(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            if index > start { lines.append(Data(data[start..<index])) }
            start = data.index(after: index)
        }
        return lines
    }
}
