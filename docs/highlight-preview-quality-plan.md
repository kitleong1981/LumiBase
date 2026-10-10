# RAW 高光還原預覽品質模式規劃書 (RAW Highlight Recovery Preview Quality Plan)

## 1. 背景與目標

### 1.1 背景
在 v1.14.14 中，LumiBase 成功導入了參考 Lightcraft 架構的 GPU 高光還原管線（雙曝光 HDR 線性輻照度重構 + 對數空間保邊導向濾波 + 延伸 Reinhard 膠片映射）。
然而，目前在螢幕預覽（Fit to screen 檢視或拉動滑桿）時，系統仍強制對全尺寸 3,300 萬（或 6,100 萬）畫素之原始 RAW 影像執行雙重完整 demosaic 與全解析度濾波運算。這導致在 Apple Silicon M4 晶片上，預覽與互動仍帶有數百毫秒的計算負擔，無法達到每秒 60~120fps 的即時流暢感。

### 1.2 目標
1. 在設定視窗（**LumiBase Fast Library Settings**，即 `PerformanceSettingsView`）中新增「RAW 高光還原預覽模式（Highlight Recovery Preview Quality）」設定選項。
2. 提供兩種模式供使用者選擇：
   - **快速模式（Fast / Screen-res，預設）**：在一般檢視與滑桿互動時，採用螢幕代理解析度（長邊約 2560px）進行高光運算，計算量與 VRAM 頻寬減少 90%，在 M4 上達成個位數毫秒級（< 10ms）超流暢反應。
   - **全解析度模式（Full Resolution / Accurate）**：維持現況，預覽時亦始終以全尺寸原圖進行雙重 demosaic 與濾波。
3. **無損匯出保證**：無論使用者在設定中選擇哪種預覽模式，「100% 像素檢視」與「JPEG 匯出（PhotoExportService）」永遠強制採用 100% 全解析度運算，確保最終產出的影像細節 100% 完整無損。
4. 全面啟用 Apple Silicon M4 的 **FP16（半精度 RGBAh）** 專用硬體加速，記憶體頻寬減半，著色吞吐量翻倍。

---

## 2. 架構設計與變更規劃

### 2.1 資料模型與設定持久化 (`PerformanceSettings.swift`)

1. 定義預覽品質列舉：
   ```swift
   public enum HighlightPreviewQuality: Int, CaseIterable, Identifiable {
       case fast = 0    // 低解析度快速模式（預設）
       case full = 1    // 高解析度完整模式
       
       public var id: Int { rawValue }
       public var title: String {
           switch self {
           case .fast: return "Fast (Screen-res / Default)"
           case .full: return "Full Resolution (Accurate)"
           }
       }
   }
   ```
2. 在 `PerformanceSettings` 中加入：
   ```swift
   @Published public var highlightPreviewQuality: HighlightPreviewQuality {
       didSet {
           defaults.set(highlightPreviewQuality.rawValue, forKey: "highlightPreviewQuality")
           RAWImageLoader.shared.clearCache()
           NativeHighlightsService.shared.clear()
           NotificationCenter.default.post(name: NSNotification.Name("LumiBaseRefreshDisplay"), object: nil)
       }
   }
   ```
3. 預設讀取邏輯：
   ```swift
   let qualityVal = defaults.object(forKey: "highlightPreviewQuality") as? Int ?? HighlightPreviewQuality.fast.rawValue
   highlightPreviewQuality = HighlightPreviewQuality(rawValue: qualityVal) ?? .fast
   ```

### 2.2 UI 介面設計 (`PerformanceSettingsView`)

在 `PerformanceSettingsView` 表單中新增 Section：
```swift
Section("RAW Highlight Recovery Preview Quality") {
    Picker("Preview quality", selection: $settings.highlightPreviewQuality) {
        ForEach(HighlightPreviewQuality.allCases) { quality in
            Text(quality.title).tag(quality)
        }
    }
    .accessibilityIdentifier("highlightPreviewQuality")
    
    Text("Fast (Default): Uses screen-resolution proxies (2560px) during regular viewport inspection and live slider adjustments for instant, fluid 120fps performance on Apple Silicon. Full 1:1 inspection and JPEG exports always use 100% native resolution.\n\nFull Resolution: Always performs multi-exposure RAW demosaicing and guided filtering across the entire full-frame sensor grid, even for scaled viewports.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

### 2.3 渲染管線對接 (`RAWImageLoader.swift` & `NativeHighlightsService.swift`)

1. **`RAWImageLoader.renderProcessed`**：
   - 判斷是否需要跑滿 full resolution：
     ```swift
     let isFullResolution = fullResolution || PerformanceSettings.shared.highlightPreviewQuality == .full
     ```
   - 根據 `isFullResolution` 決定將 `targetExtent` 傳給 `NativeHighlightsService.image`。
2. **`NativeHighlightsService`**：
   - 在 Fast 模式（非 fullResolution 且非 export）下，啟用 `raw.isDraftModeEnabled = true`，繞過耗時的全畫素 Bayer demosaicing。
   - 將 `renderContext` 的 `.workingFormat` 由 `.RGBAf` 調整為 `.RGBAh`（16-bit half float），完整釋放 M4 GPU FP16 加速能力。

### 2.4 設定入口位置調整與分頁結構 (Tabbed Settings)

1. **設定入口遷移至全域頂部工具列 (`TopFilterBarView.swift`)**：
   - 原先放置於 `LoupeView` 浮動覆蓋層的齒輪圖示僅在 Library 模式顯示，容易造成誤解。
   - 將齒輪按鈕 (`SettingsLink`) 移至頂部篩選列（Rating / Flag 列）的最右端，使其成為全域常駐功能（無論在庫或修圖模式皆可快速打開）。
   - 支援快速鍵 `⌘,` 呼叫標準 macOS 偏好設定視窗。
2. **設定視窗分頁設計 (`PerformanceSettingsView`)**：
   - 使用標準 `TabView` 結構分類管理設定項目：
     - **圖庫快取 (Library & Cache)**：包含 Library JPEG 100% ROI 鄰近快取半徑、容量預算、條目統計與清理快取。
     - **影像算力 (Rendering & RAW)**：包含 RAW 高光還原預覽品質（快速模式 / 完整解析度）、全片幅感光元件銳利度分析分數開關。
     - **一般設定 (General)**：包含 Loupe 直方圖預設開關、版本資訊與快速鍵說明。

---

## 3. 測試與驗證計畫

1. **單元測試驗證**：
   - `testHighlightPreviewQualitySettingsAndFastRender`：驗證設定切換與持久化，以及 Fast / Full 預覽算力。
   - `testHostedSettingsReadUpdateAndClear`：驗證 TabView 架構下圖庫快取 NSPopUpButton 正確掛載與控制。
   - 驗證 `PhotoExportService` 在兩種模式下均維持 100% 全解析度高光還原。
2. **實機互動效能驗證**：
   - 測試拉動 Highlights 滑桿的即時 FPS 與延遲。
   - 測試 Fit to screen 切換與 100% 縮放檢視的切換流暢度。
