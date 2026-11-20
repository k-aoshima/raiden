import Foundation

extension Array {
    /// 順番を保ったまま、要素ごとの変換を複数のコアで行う（16 万件の名前のローマ字・説明文づくりなど、要素どうしが独立な物だけ）。
    /// 少ないときはそのまま map
    func parallelMap<T>(minCount: Int = 4096, _ f: (Element) -> T) -> [T] {
        let n = count
        guard n >= minCount else { return map(f) }
        let chunks = Swift.max(1, Swift.min(ProcessInfo.processInfo.activeProcessorCount * 2, n / 512))
        let size = (n + chunks - 1) / chunks
        var out = [T?](repeating: nil, count: n)
        out.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            withoutActuallyEscaping(f) { f in
                self.withUnsafeBufferPointer { src in
                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                        let lo = c * size, hi = Swift.min(n, lo + size)
                        guard lo < hi else { return }
                        for i in lo..<hi { (p + i).pointee = f(src[i]) }
                    }
                }
            }
        }
        return out.map { $0! }
    }
}
