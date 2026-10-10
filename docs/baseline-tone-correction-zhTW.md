# LumiBase 基準階調修正（Baseline Tone Correction）

> 狀態：實驗性，預設開啟。僅作用於 RAW。依賴 PR #13（Lightcraft 高光 v1.14.14），請在其合併後再審。

## 背景

「全部歸零」的 RAW 渲染（baseline）和 Lightroom（LR）有穩定的差異：LumiBase 的暗到中間調偏暗、彩度偏高，亮部彩度也偏高（橘紅、黃特別明顯）。baseline 不一致會讓所有高光調整的比較都失真，所以我們先修 baseline，再回頭調高光。

渲染鏈目前是 Apple `CIRAWFilter`（`boostAmount = 1.0`）加上 `AdobeColorPipeline` 的調整；Adobe 的 DCP profile 並沒有進入渲染（`DCPProfileManager` 只用於 UI 標籤）。

## 做了什麼

`AdobeColorPipeline.process` 結尾（僅 RAW）新增 `BaselineToneKernel`，一個 Core Image 色彩 kernel，在 CIELAB 空間處理：

| 範圍 | 處理 | 預設 |
|---|---|---|
| L\* 約 1 到 35（暗到中間調，平滑過渡） | 亮度抬升 | +3 L\* |
| 同上 | 彩度縮放 | ×0.80 |
| L\* ≥ 45（亮部，從 45 到 75 平滑過渡） | 彩度縮放 | ×0.88 |

範圍之外的像素原封不動，並保留超出色域的數值。

開關與調整：
- 關閉：`defaults write com.lumibase.LumiBase.FastLibrary baselineToneCorrection -bool false`，或環境變數 `LB_BASELINE_A=0`。
- 實驗用環境變數：`LB_BA_LIFT`、`LB_BA_CHROMA`、`LB_BA_BRIGHT`。

## 量測方法與結果

基準是 **LR 匯出**（`A7RV/DSC0xxxx_raw.jpg`，LR Classic 15.6，Profile = Adobe Standard，全部調整歸零），sRGB，縮到 2000 px，以 Lab ΔE76 比較。重現方式：

```bash
LUMIBASE_DIAG_ONLY=h0 LUMIBASE_DIAG_DNG=<ARW> LUMIBASE_DIAG_OUT=<dir> \
  swift test --filter HighlightsDiagTests/testBalloonVariants
python3 scripts/lr_compare.py <LR 匯出.jpg> <dir>/h0.png
```

10 張 ARW（A7RV，氣球節）：

| 照片 | 修正前 ΔE | 修正後 ΔE |
|---|---|---|
| 1141 | 4.36 | 4.09 |
| 1174 | 10.17 | 6.43 |
| 1204 | 5.72 | 5.34 |
| 1232 | 4.47 | 4.19 |
| 1272 | 3.35 | 3.13 |
| 1330 | 9.15 | **9.73（退步）** |
| 1345 | 10.73 | 9.37 |
| 1358 | 7.03 | 6.95 |
| 1406 | 3.76 | 3.25 |
| 1423 | 6.06 | 5.84 |
| **平均** | **6.48** | **5.83** |

## 已知限制（請務必閱讀）

- **場景偏窄：** 10 張都是同一場活動（氣球節，夜景與清晨），沒有膚色、綠葉、日光場景。尚未做這些類型的驗證。
- **1330 退步：** 這張 LR 的紅橘與黃比修正後的 LumiBase 更飽和，表示「全部降彩度」並不普遍成立，彩度差異依場景而變。
- **1345 沒修乾淨：** 藍青色區域 LR 比 LumiBase 亮約 11 L\*，這個修正只能解決一部分。
- **雜訊底線：** 大約 1.5 的 ΔE 來自縮圖重採樣、銳化與邊緣對位，不是顏色。模糊後平均 ΔE 為 4.27。
- **只做 Sony ILCE-7RM5 ARW 與 DxO DNG：** 其他機型未驗證。DxO 的 Linear DNG 與 ARW 的差異（亮部彩度）可能需要分開處理。
- **擬合方式：** 三個參數由 10 張照片擬合，留一驗證均為進步或持平，但仍可能過擬合到這批樣本。
- **Sony JPG 不是可靠基準：** 實測 Sony JPG 與 LR 歸零的 ΔE 約 6，與 LumiBase 對 LR 的差距相當；這批 JPG 也都開啟 DRO Auto。因此本文件只採用 LR 匯出為基準。
- **會影響其他比較：** 此修正改變所有 RAW 的暗部與彩度，先前以舊 baseline 做的高光比較（含 PR #13 的數據）需要以新 baseline 重跑。

## 試過但沒有採用

- **套用 Adobe DCP（HueSatMap／LookTable）的離線試驗：** 對 Apple 線性輸出套用 `Sony ILCE-7RM5 Adobe Standard.dcp`，再擬合全域曲線，10 張平均 ΔE 為 12 以上，比現況（5.75）差很多。結果更可能是我們的重新實作或色彩基底不相容，**不能據此斷定 DCP 無用**。若要認真走這條路，需要以 Adobe 官方實作做 ground truth。
- **通用 Lab 查表：** 以亮度、色相、彩度的 1,344 個格子擬合，留一驗證平均 5.73，沒有比三個參數的簡單修正好。
- **全域 a\* 偏移：** 補償灰階偏洋紅的趨勢，整體 ΔE 反而變差。

## 測試

- `BaselineToneKernelTests`：黑色與中性灰不變；暗藍被抬亮且去飽和；亮部飽和橘去飽和但亮度不變。
- `HighlightsDiagTests`：需要環境變數才會執行的診斷工具（渲染 H0／標準 −80／Advanced −80 與 Apple 線性輸出），一般 `swift test` 會跳過。
