import Foundation
import AppKit
import ImageIO

// One read-only decode per process. Exiting releases ImageIO/allocator intermediates.
// Output: seven Int64 fields (w,h,bottom-origin x,y,fullW,fullH,EXIF orientation), RGBA8.
let args = CommandLine.arguments
func run() -> Bool {
    guard args.count == 7, let cx = Double(args[2]), let cy = Double(args[3]), let vw = Double(args[4]), let vh = Double(args[5]), let scale = Double(args[6]),
          [cx, cy, vw, vh, scale].allSatisfy({ $0.isFinite }), vw > 1, vh > 1 else { return false }
    let url = URL(fileURLWithPath: args[1])
    guard ["jpg", "jpeg"].contains(url.pathExtension.lowercased()),
          let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return false }
    let options: [CFString: Any] = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
    guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          max(full.width, full.height) == max(width, height), min(full.width, full.height) == min(width, height) else { return false }
    let w = min(full.width, Int(ceil(vw * max(1, scale) + 512))), h = min(full.height, Int(ceil(vh * max(1, scale) + 512)))
    let x = min(full.width - w, max(0, Int(floor(min(1, max(0, cx)) * Double(full.width) - Double(w) / 2))))
    let y = min(full.height - h, max(0, Int(floor((1 - min(1, max(0, cy))) * Double(full.height) - Double(h) / 2))))
    let cost = w * h * 4
    guard cost > 0, cost <= 48 * 1024 * 1024, let memory = calloc(cost, 1),
          let context = CGContext(data: memory, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    defer { free(memory) }
    context.interpolationQuality = .none
    context.draw(full, in: CGRect(x: -x, y: -y, width: full.width, height: full.height))
    let header: [Int64] = [Int64(w), Int64(h), Int64(x), Int64(y), Int64(full.width), Int64(full.height), Int64(props[kCGImagePropertyOrientation] as? Int ?? 1)]
    header.withUnsafeBytes { FileHandle.standardOutput.write(Data($0)) }
    FileHandle.standardOutput.write(Data(bytes: memory, count: cost))
    return true
}
let ok = autoreleasepool { run() }
exit(ok ? 0 : 1)
