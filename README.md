# LumiBase

## Fast Library 1.14.11：修正啟動只開 Settings

主 WindowGroup 改為預設 launch scene；主窗關閉、Settings 保留時，Finder／Dock 明確 reopen 會回到主工作區，不在普通 activate 強制開窗，也不重複建立已有主窗。保留原本 ROI／sharpness 偏好、前版 HOLD 點擊錨點與鍵盤路由，不清除 preferences。

詳見 [1.14.11 啟動／reopen RED→GREEN 與限制](docs/1.14.11-fast-library-zhTW.md)。完整 Release 238 tests／36 skipped／0 failures；native Settings key-focus 首次仍失敗，後續兩次未放寬 assertions 的實際 host 通過。

## Fast Library 1.14.10：左鍵 HOLD 100% 點擊錨點

快速換照片、仍顯示該照片自己的 resident preview 時，左鍵按住現在先記下 Fit／letterbox 內的實際點擊位置，再放大，不再只設 held 而沿用圖片中心。裁切 Library 的 Fit→native metadata 使用同一 full processed output extent，避免後續縮放跳位；靠近邊緣仍會防黑邊 clamp。按住／放開回 Fit、Z／完成雙擊才持續、ROI／Trash hold／全解析度 sharpness 規則不變。

詳見 [1.14.10 座標 RED/GREEN、實拍 crop 與驗證限制](docs/1.14.10-fast-library-zhTW.md)。完整 Release 235 tests／36 skipped／0 failures；本次 native Settings key-focus 複驗仍未取得 key window，失敗明列，不冒稱通過。

## Fast Library 1.14.9：全解析度 Sharpness 與原生 Settings

Develop 返回 Library，Loupe／Grid／Filmstrip 預設顯示處理後的曝光、色調與裁切；未編輯照片仍用快速 camera JPEG，星等／旗標不是修圖。已編輯 RAW 100% 對選取照片使用準確 native pipeline，未裁切可用 processed ROI，裁切走 full processed render。RAW-only Fit 使用內嵌 JPEG；無足尺寸 JPEG 時，100% 對當前照片 on-demand RAW 解碼，不把 proxy 冒充原生。

**⌘, → Sharpness / Full resolution — Experimental** 可開啟右下角 **Sharpness · Full resolution**（新偏好預設 OFF、既有 ON 保留）。分析選取照片實際原生全圖，不是 1600px proxy 放大或 viewport ROI；已編輯照片分析相同修圖／裁切的 full processed output，並標示來源和實際像素尺寸。保留 64px Laplacian 最銳利 10% blocks 相對指標，不是對焦信心／自動淘汰。可能額外解碼完整 JPEG 或選取 RAW，增加 CPU／瞬間 RAM；顯示畫面不等待 score。實測原生 9504×6336 JPEG：1801 **131.42**、1803 **439.53**，詳細三輪 hosted OFF／ON 與代價見新版本文件。舊 122–131ms 診斷不是新版本保證。

保留已接受的 Fast Library 簡化 UI、相機 JPEG 快速預覽與安全背景 Trash。按 **⌘,** 開啟原生 Settings → **Performance / Cache**：Library JPEG ROI 實驗可選 OFF（新偏好設定預設）／前後各 1／前後各 2，另選 64／128／256 MiB 預算，查看用量及清空快取。明確選擇會在重啟後保留；快取預算不是 app + helper RSS 上限，完整 JPEG 解碼仍有瞬間記憶體尖峰。暖 native hit 不一定較慢，請保持實驗 opt-in。

詳見 [1.14.9 全圖指標、效能與驗證](docs/1.14.9-fast-library-zhTW.md)；[1.14.8 Settings Escape 修正](docs/1.14.8-fast-library-zhTW.md)保留。

> **Native macOS Digital Asset Manager (DAM) for Camera RAW & XMP workflows on Apple Silicon.**

LumiBase 是一套專為 macOS (特別是 Apple Silicon M 系列晶片) 打造的高效能 RAW 相片資產管理軟體。提供如 Adobe Lightroom Classic 般的直覺介面、秒級選圖反應、精確的 Adobe Camera RAW 色彩還原，以及非破壞性的雙向 XMP Sidecar 中繼資料同步。

---

## 🌟 核心特色 (Key Features)

- ⚡ **極速 RAW 解碼與 120fps 即時預覽引擎**：
  - 基於 Apple Silicon 統一記憶體架構、Metal 硬體加速與 `LiveDevelopPreviewEngine` 獨立後台合併隊列（Coalescing Queue）。
  - 創新多階層顯示代理（1440px 極速互動代理、2560px 螢幕代理、全解析度原圖），滑桿調整單幀 GPU 耗時壓至 $< 0.4\text{ms}$，跑滿 ProMotion 120fps 極限流暢度。
- 🎛️ **1:1 媲美 Lightroom Classic 的 Develop Basic 修圖模組**：
  - **白平衡 (WB)**：2000K ~ 50000K 色溫、-150 ~ +150 色調、完整色溫預設檔（As Shot、Auto、Daylight、Cloudy、Shade、Tungsten、Fluorescent、Flash、Custom）。
  - **處理模式 (Treatment)**：一鍵 Color / Black & White 切換，黑白模式下自動聯動 `crs:ConvertToGrayscale="True"` 並隱藏彩度滑桿。
  - **色調控制 (Tone)**：線性光子曝光（-5.00 ~ +5.00 EV）、對比、雙階段高光還原（Apple 雙邊濾波挽救死白雲層）、全域陰影提升/加深、極致白色端點與黑色沉澱。
  - **外觀控制 (Presence)**：紋理（正向微距毛髮銳利、負向人像皮膚自然磨皮）、清晰度（正向中頻對比、負向浪漫夢幻柔焦）、去朦朧（大氣去霧/加霧）、自然飽和度（膚色保護）與標準線性飽和度。
  - **精緻滑桿組件 (`LightroomSlider`)**：0ms 本機跟手手感、雙擊標題/軌道復位、**點擊/雙擊數值標籤直接進入打字輸入，支援 `Tab` / `Shift+Tab` 在各修圖選項間連續跳轉切換，按 Enter 即刻套用**。
- 🔄 **Lightroom 等級 Develop Sync 批次同步與修圖管理**：
  - **選擇性同步 (Sync Settings Dialog)**：`⌘⇧S` 快捷鍵或右側底部 `Sync` 按鈕，支援選擇性勾選白平衡、基礎曝光、Presence、相機描述檔、黑白處理與幾何裁切，提供 `Check All`、`Check None` 與 `Modified Only` 智慧過濾。
  - **即時自動同步 (Auto Sync)**：`⌥⌘⇧S` 快捷鍵或點選 Auto Sync 開關，開啟後多選照片拉動任一滑桿即時連動所有選取照片。
  - **複製／貼上設定 (Copy & Paste Settings)**：`⌘⇧C` 複製自訂修圖設定，`⌘⇧V` / `⌥⌘V` 批次貼上至選取照片。
- 🪞 **媲美 Lightroom Classic 的 Before / After 即時對比檢視引擎**：
  - **單鍵切換原圖 (`\`)**：按下瞬切相機原始 As Shot 影像與當前調色，角落懸浮浮水印提示。
  - **左右分割對比 (Left/Right Split, `Y`)**：左側原圖、右側調色後，中間具備原生手柄與分隔線，可自由左右拖動，雙擊手柄立即居中復位。
  - **雙圖並排檢視 (Side-by-Side 2-Up, `⇧Y`)**：左右雙圖並列，雙圖 100% 畫素放大（1:1 Inspection）與滑鼠漫遊拖曳完全同步聯動。
  - **上下分割對比 (Top/Bottom Split)**：水平分隔線自由滑動，適合橫幅風景高光天空對比。
  - **0 延遲極速渲染**：Before 影像於後台單次解碼快取，調色時 Before 零 GPU 重複耗時，維持 Apple Silicon 120fps 滑桿手感。
- 🎨 **1:1 Adobe Camera RAW 色彩還原**：
  - 整合 **Adobe Standard DCP (Digital Camera Profile)** 管理管線。
  - 完整支援 Adobe PV2012 色彩管線（曝光、色溫/色調、高光/陰影、對比、白色/黑色、鮮豔度、飽和度、去朦朧）。
  - 確保 **Grid 縮圖**、**Filmstrip 底片列** 與 **Loupe 大圖預覽** 色彩 100% 完全一致。
- 📂 **檔案總管樹狀目錄導覽 (File Explorer Tree)**：
  - 無限制層級目錄展開與即時瀏覽，智慧過濾系統隱藏與虛擬卷宗。
  - 直接存取本機目錄與外接 SSD/隨身碟（如 `/Volumes/Super SSD`）。
  - 自動記錄並持久化「最近開啟的 5 個目錄」（RECENT FOLDERS），置頂於左側欄上方。
- 🔄 **雙向 XMP Sidecar 同步 (Non-Destructive)**：
  - 支援讀取與寫入標準 Adobe `.xmp` 副檔。
  - 評星等（Rating）、旗標（Pick/Reject）或調整任何 Develop 參數時自動防抖寫入 `.xmp`，不修改 RAW 原檔，並可無縫在 Adobe Lightroom Classic / Bridge / Capture One 中開啟。
- 📤 **媲美 Lightroom 的 RAW+XMP 高畫質 JPEG 匯出**：
  - 感光元件全解析度 Demosaicing 算圖。
  - 完美套用 Adobe PV2012 色彩管線。
  - 完整保留相機機身、鏡頭、快門、光圈、ISO、日期與 GPS 等 EXIF 中繼資料。
  - 強制轉換並標記 `sRGB` 色彩空間與 ICC Profile，在各種裝置與螢幕上色彩鮮明一致。
  - 支援批次匯出與即時進度浮動 HUD。
- ⌨️ **Lightroom 經典快捷鍵操作**：
  - **全選與取消全選**：`⌘A` (Command + A) 全選目前網格照片，`⌘D` (Command + D) 取消全選。
  - **搜尋照片**：`⌘F` (Command + F) 快速聚焦頂部搜尋欄，按 `Enter` 或 `Esc` 退出搜尋並恢復單鍵快捷鍵。
  - **Before / After 即時對比**：`\` 瞬切原圖 As Shot 與調色，`Y` 循環切換對比版面（分割/並排），`⇧Y` 反向循環。
  - **連續多選與範圍選取**：按住 `Control` / `⌘` 點選照片進行多選加減選；按住 `Shift` 點選兩張照片進行連續範圍全選。
  - **安全刪除 (Move to Trash)**：`⌘⌫` (Command + Backspace) 快速刪除選取照片，並同步清理 `.xmp` 側邊副檔，刪除前具備原生確認對話框。
  - **匯出**：`⇧⌘E` (Shift + Command + E) 快速匯出選取（或全部）照片為高品質 JPEG。
  - **Grid 2D 導覽**：`↑` / `↓` 整行跳轉，`←` / `→` 前後選取。
  - **檢視切換**：`Enter` / `Return` / `E` / `Space` 進入大圖預覽（Loupe View），`Esc` / `G` 返回網格（Grid View）。
  - **100% 畫素縮放 (Zoom 1:1)**：`Z` 鍵或雙擊滑鼠在「Fit 全圖適配」與「100% 原生畫素」間切換。
  - **評分與旗標**：`0~5` 快速評星等，`P` 標記留用（Pick），`X` 標記剔除（Reject），`U` 取消標記（Unflag）。
  - **面板收合**：`Tab` 鍵快速收合/展開左右兩側面板，`F7` 獨立切換左面板，`F8` 獨立切換右面板。

---

## 📸 支援格式 (Supported Formats)

- **RAW 格式**：
  - Sony (`.ARW`)
  - Canon (`.CR2`, `.CR3`)
  - Nikon (`.NEF`)
  - Adobe / Leica / Apple ProRAW (`.DNG`)
  - Fujifilm (`.RAF`)
  - Panasonic (`.RW2`)
  - Olympus / OM System (`.ORF`)
- **通用圖片格式**：
  - JPEG (`.JPG`, `.JPEG`), TIFF (`.TIF`, `.TIFF`), HEIC, PNG

---

## ⌨️ 快速鍵一覽 (Keyboard Shortcuts)

| 動作 | 快捷鍵 |
| :--- | :--- |
| **開啟資料夾 (Open Folder)** | `⌘O` (Command + O) |
| **全選所有照片 (Select All)** | `⌘A` (Command + A) |
| **取消全選 (Deselect All)** | `⌘D` (Command + D) |
| **連續多選照片 (Multi-Select)** | 按住 `Control` 或 `⌘` 點選照片 |
| **連續範圍選取 (Range Select)** | 點選起始照片，按住 `Shift` 點選結束照片 |
| **移至垃圾桶 (Move to Trash)** | `⌘⌫` (Command + Backspace) |
| **匯出至高品質 JPEG (Export)** | `⇧⌘E` (Shift + Command + E) |
| **進入大圖預覽 (Loupe View)** | `Enter` / `Return`、`E`、雙擊滑鼠 |
| **返回圖庫網格 (Grid View)** | `Esc`、`G` |
| **切換 網格 / 預覽** | `Space` (空白鍵) |
| **100% 畫素放大 (Zoom 1:1)** | `Z` / 雙擊滑鼠 |
| **切換照片 EXIF 資訊 HUD** | `I` |
| **網格上下行移動** | `↑` (上鍵) / `↓` (下鍵) |
| **上一張 / 下一張** | `←` (左鍵) / `→` (右鍵) |
| **設定評分 (Rating)** | `0` (無)、`1` ~ `5` 星、`[` (降星)、`]` (升星) |
| **標記旗標 (Flag)** | `P` (Pick 留用)、`X` (Reject 剔除)、`U` (Unflag 取消) |
| **聚焦搜尋欄 (Search)** | `⌘F` (Command + F) |
| **收合/展開兩側面板** | `Tab` |
| **切換左側導覽列 (Left Sidebar)** | `F7` |
| **切換右側檢查器 (Right Inspector)** | `F8` |
| **裁切與旋轉校正 (Crop Tool)** | `R` (開啟/套用關閉) |
| **循環切換裁切輔助格線 (Overlay)** | `O` (裁切模式下) |
| **翻轉裁切方向 (Flip Orientation)** | `X` (裁切模式下) |
| **複製修圖設定 (Copy Settings)** | `⇧⌘C` (Shift + Command + C) |
| **貼上修圖設定 (Paste Settings)** | `⇧⌘V` (Shift + Command + V) / `⌥⌘V` |
| **同步修圖設定 (Sync Settings)** | `⇧⌘S` (Shift + Command + S) |
| **開關自動同步 (Toggle Auto Sync)** | `⌥⇧⌘S` (Option + Shift + Command + S) |
| **切換 Before/After 原圖對比** | `\` (反斜線) |
| **循環切換對比模式 (Split/Side-by-Side)** | `Y` (前進) / `⇧Y` (後退) |

> 💡 **全介面 Tooltip 提示**：滑鼠游標停留在介面上的任意按鈕、圖示、選單或評分旗標上約 1 秒，即可看見原生 Tooltip 提示與對應的鍵盤快捷鍵。

---

## 🏗️ 架構與模組 (Architecture)

```
LumiBase/
├── App/                  # App 生命週期與 AppState 全域狀態中心 (即時調色狀態隔離)
├── Models/               # PhotoAsset、XMPMetadata (PV2012/Grayscale)、CameraMetadata、FilterCriteria
├── Services/
│   ├── FileSystem/       # DirectoryWatcher (FSEvents), FolderScanner
│   ├── Image/            # AdobeColorPipeline (Metal/PV2012), LiveDevelopPreviewEngine (120fps), RAWImageLoader, ThumbnailLoader
│   └── Metadata/         # XMPParser, XMPWriter (PV2012 / ConvertToGrayscale), MetadataReader (EXIF)
├── Theme/                # LightroomTheme 深灰色系主題、LightroomSlider (漸層/手感/輸入)
└── Views/                # GridView, LoupeView, FilmstripView, DevelopBasicPanelView, RightInspectorView, LeftSidebarView
```

---

## 🛠️ 開發與建置需求 (Requirements & Build)

- **系統需求**：macOS 14.0 (Sonoma) 或更新版本
- **硬體推薦**：Apple Silicon Mac (M1 / M2 / M3 / M4)
- **開發工具**：Xcode 15.0+ / Swift 5.9+

### 建置與測試指令

```bash
# 執行單元測試
swift test

# 建置 macOS 應用程式
xcodebuild -scheme LumiBase -destination 'platform=macOS' build

# 📦 一鍵打包產出 macOS DMG 安裝檔
./package_dmg.sh
```

---

## 📖 專案文件與版本紀錄 (Documentation & Changelog)

- 📖 **使用者操作手冊與快捷鍵教學 (Usage Guide)**：[`docs/USAGE_GUIDE.md`](docs/USAGE_GUIDE.md)
- 📝 **版本更新日誌 (Changelog)**：[`CHANGELOG.md`](CHANGELOG.md)
- 📐 **架構演進與實作紀錄**：[`docs/implementation-record.md`](docs/implementation-record.md)
- ✂️ **裁切與旋轉校正規格書**：[`docs/crop-and-rotate-plan.md`](docs/crop-and-rotate-plan.md)
- 🔄 **批次修圖同步規劃書**：[`docs/develop-sync-plan.md`](docs/develop-sync-plan.md)

