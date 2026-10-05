import Foundation
import SwiftUI

// MARK: - 液态玻璃能力探测
//
// Beans Music 的玻璃风格在 iOS 26 上使用系统原生 Liquid Glass（`.glassEffect`）。
// 在 iOS 26 以下：
//   * 普通设备 —— 回退到系统材质（`.ultraThinMaterial` / `.regularMaterial`）。
//   * 越狱 + 安装了 Liquidass 插件的设备 —— Liquidass 会在系统层面把
//     `.ultraThinMaterial` 这类系统材质实时重绘成 iOS 26 的液态玻璃效果，
//     因此这里只需保证走"系统材质"路径，插件效果即可自然作用于 App。
//
// 本类型不做任何自绘玻璃模拟，只负责判定应当使用哪一条系统材质路径。
enum BeansGlassSupport {

    /// 是否具备系统原生 `.glassEffect`（iOS 26 及以上）。
    static var hasNativeGlassEffect: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    /// 是否检测到 Liquidass 越狱插件。
    ///
    /// 仅在越狱设备上可能为 true。检测方式是查找插件注入的动态库或偏好文件，
    /// 覆盖常见越狱环境（RootHide / Dopamine / palera1n / unc0ver 等）的路径。
    static let liquidassInstalled: Bool = {
        let candidates = [
            // TweakInject / Substrate
            "/usr/lib/TweakInject/Liquidass.dylib",
            "/usr/lib/TweakInject/liquidass.dylib",
            "/Library/MobileSubstrate/DynamicLibraries/Liquidass.dylib",
            "/Library/MobileSubstrate/DynamicLibraries/liquidass.dylib",
            // rootless 越狱（Dopamine / palera1n rootless）前缀
            "/var/jb/usr/lib/TweakInject/Liquidass.dylib",
            "/var/jb/usr/lib/TweakInject/liquidass.dylib",
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/Liquidass.dylib",
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/liquidass.dylib",
            // RootHide
            "/var/mobile/Library/Preferences/com.winaviation.liquidass.plist",
            "/var/jb/var/mobile/Library/Preferences/com.winaviation.liquidass.plist",
            "/var/mobile/Library/Preferences/com.dylv.liquidass.plist",
            // ElleKit（rootless）
            "/var/jb/usr/lib/ellekit/Liquidass.dylib",
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }()

    /// 是否应当让 App 走"系统材质"路径。
    ///
    /// - iOS 26+：走原生 `.glassEffect`。
    /// - 越狱 + Liquidass：走系统材质，让插件把材质重绘为液态玻璃。
    /// - 其他：同样走系统材质（普通毛玻璃），不再自绘模拟。
    static var prefersSystemMaterial: Bool { true }

    /// 是否应当使用原生 `.glassEffect`（含被 Liquidass 强化的系统材质场景）。
    static var usesLiquidAppearance: Bool {
        hasNativeGlassEffect || liquidassInstalled
    }
}

// MARK: - 系统材质枚举

/// App 内统一的"玻璃"外观等级。全部映射到 SwiftUI 原生材质，不做自绘。
enum BeansMaterialLevel {
    /// 控件的薄玻璃（胶囊按钮、图标底、行背景）
    case thin
    /// 卡片的常规玻璃
    case regular
    /// 需要更强可读性的厚玻璃
    case thick

    var material: Material {
        switch self {
        case .thin: return .ultraThinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        }
    }
}

// MARK: - 统一玻璃修饰器

/// 把任意形状填成系统玻璃材质（Liquidass 环境会由插件接管渲染）。
struct BeansGlassBackground<S: Shape>: View {
    let shape: S
    var level: BeansMaterialLevel = .thin
    var forceNative = false

    var body: some View {
        if #available(iOS 26, *), (forceNative || BeansGlassSupport.hasNativeGlassEffect) {
            GlassEffectContainer {
                shape
                    .fill(.clear)
                    .glassEffect(.clear, in: shape)
            }
        } else {
            shape.fill(level.material)
        }
    }
}

extension View {
    /// 给视图套一层系统玻璃背景（形状自定）。
    func beansGlassBackground<S: Shape>(
        _ shape: S,
        level: BeansMaterialLevel = .thin,
        forceNative: Bool = false
    ) -> some View {
        background {
            BeansGlassBackground(shape: shape, level: level, forceNative: forceNative)
        }
    }
}
