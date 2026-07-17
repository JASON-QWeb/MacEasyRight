import Foundation

// MARK: - 长截图拼接算法(纯计算,不依赖 AppKit,便于单独测试)

public struct StitchFrame {
    public let width: Int
    public let height: Int
    public let bands: Int

    /// 每行切成多个横向小块后得到的感知哈希。忽略左右边缘，避免滚动条影响匹配。
    public let bandHashes: [UInt64]
    /// 标记有纹理/文字的小块；匹配时不让大片纯色背景稀释真正的差异。
    public let informative: [Bool]

    /// pixels 为 RGBA8888,行优先,width*4 字节一行
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height

        let bandCount = min(12, max(4, width / 80))
        self.bands = bandCount
        guard width > 0, height > 0, pixels.count >= width * height * 4 else {
            self.bandHashes = []
            self.informative = []
            return
        }

        var hashes = [UInt64](repeating: 0, count: height * bandCount)
        var details = [Bool](repeating: false, count: height * bandCount)
        let inset = min(max(2, width / 50), max(2, width / 8))
        let usableWidth = max(bandCount, width - inset * 2)

        pixels.withUnsafeBufferPointer { buf in
            for row in 0..<height {
                let rowBase = row * width * 4
                for band in 0..<bandCount {
                    let x0 = min(width - 1, inset + usableWidth * band / bandCount)
                    let x1 = min(width, inset + usableWidth * (band + 1) / bandCount)
                    let sampleStep = max(1, max(1, x1 - x0) / 64)
                    var h: UInt64 = 0xcbf2_9ce4_8422_2325
                    var minR: UInt8 = 255, minG: UInt8 = 255, minB: UInt8 = 255
                    var maxR: UInt8 = 0, maxG: UInt8 = 0, maxB: UInt8 = 0

                    var x = x0
                    while x < x1 {
                        let p = rowBase + x * 4
                        let r = buf[p], g = buf[p + 1], b = buf[p + 2]
                        minR = min(minR, r); maxR = max(maxR, r)
                        minG = min(minG, g); maxG = max(maxG, g)
                        minB = min(minB, b); maxB = max(maxB, b)

                        // 低 3 位通常只是抗锯齿/色彩管理噪声，量化后匹配更稳定。
                        h = (h ^ UInt64(r >> 3)) &* 0x0000_0100_0000_01B3
                        h = (h ^ UInt64(g >> 3)) &* 0x0000_0100_0000_01B3
                        h = (h ^ UInt64(b >> 3)) &* 0x0000_0100_0000_01B3
                        x += sampleStep
                    }

                    let i = row * bandCount + band
                    hashes[i] = h
                    details[i] = Int(maxR) - Int(minR) > 18 ||
                                 Int(maxG) - Int(minG) > 18 ||
                                 Int(maxB) - Int(minB) > 18
                }
            }
        }
        self.bandHashes = hashes
        self.informative = details
    }
}

public enum Stitcher {
    /// 计算新帧相对上一张“已接受帧”向上滚动了多少像素。
    /// 返回 0 = 可见内容相同(未滚动/已到底);nil = 暂时找不到可靠重叠,调用方应保留旧基准后重试。
    /// skipTopFraction:忽略帧顶部区域(容忍网页吸顶导航栏)。
    public static func scrollOffset(prev: StitchFrame, cur: StitchFrame,
                                    skipTopFraction: Double = 0.15) -> Int? {
        guard prev.width == cur.width,
              prev.height == cur.height,
              prev.bands == cur.bands,
              !prev.bandHashes.isEmpty,
              prev.bandHashes.count == cur.bandHashes.count else { return nil }

        // 左右边缘的滚动条或微小颜色变化不应被当作页面滚动。
        if prev.bandHashes == cur.bandHashes { return 0 }

        let h = prev.height
        let bands = prev.bands
        let skip = min(h - 1, max(0, Int(Double(h) * skipTopFraction)))
        let minimumOverlap = max(32, min(96, h / 6))
        var best: (offset: Int, ratio: Double, evidence: Int)?

        for offset in 1..<h {
            let overlap = h - offset
            let usableRows = overlap - skip
            if usableRows < minimumOverlap { break }

            // 最多采样约 180 行 × 12 块，足以稳定识别，同时避免大选区计算过重。
            let rowStep = max(1, usableRows / 180)
            var informativeCompared = 0
            var informativeMismatch = 0
            var allCompared = 0
            var allMismatch = 0
            var row = skip

            while row < overlap {
                let prevBase = (offset + row) * bands
                let curBase = row * bands
                for band in 0..<bands {
                    let pi = prevBase + band
                    let ci = curBase + band
                    let same = prev.bandHashes[pi] == cur.bandHashes[ci]
                    allCompared += 1
                    if !same { allMismatch += 1 }

                    if prev.informative[pi] || cur.informative[ci] {
                        informativeCompared += 1
                        if !same { informativeMismatch += 1 }
                    }
                }
                row += rowStep
            }

            let minimumEvidence = max(16, bands * 3)
            let evidence: Int
            let mismatches: Int
            if informativeCompared >= minimumEvidence {
                evidence = informativeCompared
                mismatches = informativeMismatch
            } else {
                evidence = allCompared
                mismatches = allMismatch
            }
            guard evidence > 0 else { continue }
            let ratio = Double(mismatches) / Double(evidence)

            if best == nil || ratio < best!.ratio - 0.000_001 ||
               (abs(ratio - best!.ratio) < 0.000_001 && evidence > best!.evidence) {
                best = (offset, ratio, evidence)
            }
        }

        // 小块级容错可覆盖局部动画、光标提示、懒加载图片等变化。
        guard let best, best.ratio <= 0.18 else { return nil }
        return best.offset
    }
}
