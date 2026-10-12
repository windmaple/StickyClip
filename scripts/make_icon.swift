#!/usr/bin/env swift
// Turns full-bleed square artwork into a macOS app icon:
// applies the rounded-rect ("squircle") mask with Apple's standard padding
// (824pt content on a 1024pt canvas) plus a soft drop shadow, and writes a 1024px PNG.
//
// Usage: swift scripts/make_icon.swift <artwork.png> <out-1024.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make_icon.swift <artwork.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}

let size = 1024
let content: CGFloat = 824
let inset = (CGFloat(size) - content) / 2
let radius: CGFloat = 185.4  // Apple's macOS icon grid corner radius for an 824pt tile

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// Leave room for the shadow below the tile (y is up in CG).
let tile = CGRect(x: inset, y: inset + 10, width: content, height: content)
let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
              color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(path)
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
var rect = NSRect(origin: .zero, size: art.size)
guard let cg = art.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { exit(1) }
ctx.interpolationQuality = .high
ctx.draw(cg, in: tile)
ctx.restoreGState()

guard let out = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
