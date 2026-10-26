import SwiftUI

// 面板主题：内置若干套配色，收起形态与展开面板的底色、描边与文字色都从这里取
struct PanelPalette: Equatable {
    var id: String
    var name: String
    var nameEn: String
    // 收起形态的底色与描边
    var surface: String
    var stroke: String
    // 展开面板底色与卡片底色
    var panel: String
    var card: String
    // 三级文字
    var textPrimary: String
    var textSecondary: String
    var textTertiary: String
    // 强调色与警示色
    var accent: String
    var danger: String

    var surfaceColor: Color { Theme.color(surface, fallback: .black) }
    var strokeColor: Color { Theme.color(stroke, fallback: .white) }
    var panelColor: Color { Theme.color(panel, fallback: .black) }
    var cardColor: Color { Theme.color(card, fallback: .white) }
    var primaryText: Color { Theme.color(textPrimary, fallback: .white) }
    var secondaryText: Color { Theme.color(textSecondary, fallback: .white) }
    var tertiaryText: Color { Theme.color(textTertiary, fallback: .white) }
    var accentColor: Color { Theme.color(accent, fallback: .blue) }
    var dangerColor: Color { Theme.color(danger, fallback: .red) }
}

enum PanelThemeCatalog {
    // 与 BrimDeck 1.2.1 的内置主题一致，配色按 macOS 上可读性做过微调
    static let all: [PanelPalette] = [
        PanelPalette(id: "dark", name: "深色", nameEn: "Dark",
                     surface: "#000000EE", stroke: "#17FFFFFF",
                     panel: "#0B0B0DF2", card: "#12FFFFFF",
                     textPrimary: "#F5F5F7", textSecondary: "#9EEBEBF5", textTertiary: "#61EBEBF5",
                     accent: "#0A84FF", danger: "#F2777F"),
        PanelPalette(id: "oneDark", name: "One Dark Pro", nameEn: "One Dark Pro",
                     surface: "#282C34EE", stroke: "#1FFFFFFF",
                     panel: "#21252BF2", card: "#14FFFFFF",
                     textPrimary: "#ABB2BF", textSecondary: "#99ABB2BF", textTertiary: "#66ABB2BF",
                     accent: "#61AFEF", danger: "#E06C75"),
        PanelPalette(id: "githubDark", name: "GitHub 深色", nameEn: "GitHub Dark",
                     surface: "#0D1117EE", stroke: "#1FFFFFFF",
                     panel: "#0B0F14F2", card: "#14FFFFFF",
                     textPrimary: "#E6EDF3", textSecondary: "#99E6EDF3", textTertiary: "#66E6EDF3",
                     accent: "#58A6FF", danger: "#F85149"),
        PanelPalette(id: "dracula", name: "Dracula", nameEn: "Dracula",
                     surface: "#282A36EE", stroke: "#1FFFFFFF",
                     panel: "#21222CF2", card: "#14FFFFFF",
                     textPrimary: "#F8F8F2", textSecondary: "#99F8F8F2", textTertiary: "#66F8F8F2",
                     accent: "#BD93F9", danger: "#FF5555"),
        PanelPalette(id: "nightOwl", name: "夜鸮", nameEn: "Night Owl",
                     surface: "#011627EE", stroke: "#1FFFFFFF",
                     panel: "#010F1CF2", card: "#14FFFFFF",
                     textPrimary: "#D6DEEB", textSecondary: "#99D6DEEB", textTertiary: "#66D6DEEB",
                     accent: "#82AAFF", danger: "#EF5350"),
        PanelPalette(id: "cyberpunk", name: "赛博朋克", nameEn: "Cyberpunk: Edgerunners",
                     surface: "#120B1EEE", stroke: "#33FCEE09",
                     panel: "#0D0716F2", card: "#1AFCEE09",
                     textPrimary: "#F7F7FF", textSecondary: "#99F7F7FF", textTertiary: "#66F7F7FF",
                     accent: "#FCEE09", danger: "#FF2A6D")
    ]

    static func palette(id: String) -> PanelPalette {
        all.first { $0.id == id } ?? all[0]
    }
}
