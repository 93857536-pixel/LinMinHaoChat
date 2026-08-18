// 生成 LinMinHaoChat App Icon(纯 AppKit,无第三方依赖)
// 用法: swift make_icon.swift <输出png路径>
// 输出 2048x2048(NSImage @2x),再 sips -z 1024 1024 缩到 1024
import AppKit

let size: CGFloat = 1024

guard CommandLine.arguments.count > 1 else {
    print("usage: swift make_icon.swift <out.png>")
    exit(1)
}
let outPath = CommandLine.arguments[1]

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    print("no graphics context")
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// 背景:圆角 + 渐变(深青 → 靛蓝)
let path = NSBezierPath(roundedRect: rect, xRadius: 224, yRadius: 224)
path.addClip()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.85, alpha: 1),
    NSColor(calibratedRed: 0.30, green: 0.15, blue: 0.85, alpha: 1),
])!
gradient.draw(in: rect, angle: -60)

// 装饰:右上角淡色圆(氛围)
NSColor.white.withAlphaComponent(0.10).setFill()
NSBezierPath(ovalIn: CGRect(x: 660, y: 600, width: 480, height: 480)).fill()
NSColor.white.withAlphaComponent(0.06).setFill()
NSBezierPath(ovalIn: CGRect(x: -160, y: -180, width: 420, height: 420)).fill()

// 聊天气泡(白,圆角 + 尾部小三角)
let bubble = CGRect(x: 232, y: 300, width: 560, height: 400)
let bubblePath = NSBezierPath(roundedRect: bubble, xRadius: 96, yRadius: 96)
// 气泡尾部
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 330, y: 300))
tail.line(to: NSPoint(x: 250, y: 190))
tail.line(to: NSPoint(x: 470, y: 300))
tail.close()
bubblePath.append(tail)
NSColor.white.setFill()
bubblePath.fill()

// 锁(强调色)在气泡中央
let lockColor = NSColor(calibratedRed: 0.15, green: 0.72, blue: 0.97, alpha: 1)

// 锁体
let bodyRect = CGRect(x: 432, y: 408, width: 160, height: 132)
let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 30, yRadius: 30)
lockColor.setFill()
bodyPath.fill()

// 锁梁(圆弧)
let shacklePath = NSBezierPath()
shacklePath.appendArc(withCenter: NSPoint(x: 512, y: 470), radius: 74,
                      startAngle: 180, endAngle: 0, clockwise: false)
shacklePath.lineWidth = 46
shacklePath.lineCapStyle = .round
lockColor.setStroke()
shacklePath.stroke()

// 锁孔
NSColor.white.setFill()
NSBezierPath(ovalIn: CGRect(x: 488, y: 452, width: 48, height: 48)).fill()

// 三条装饰线(白色,在气泡内底部,模拟消息)
NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.75, alpha: 0.9).setFill()
NSBezierPath(roundedRect: CGRect(x: 320, y: 336, width: 300, height: 34), xRadius: 17, yRadius: 17).fill()
NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.75, alpha: 0.5).setFill()
NSBezierPath(roundedRect: CGRect(x: 320, y: 286, width: 210, height: 30), xRadius: 15, yRadius: 15).fill()

image.unlockFocus()

// 写出 PNG(NSImage 在 @2x 屏幕渲染 → 2048px)
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("failed to render png")
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("written: \(outPath) (\(png.count) bytes)")
