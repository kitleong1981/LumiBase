# 光學曝光管線改造規劃書 (Optical Exposure Pipeline Plan)

## 1. 背景與問題分析 (Background & Problem Analysis)

### 1.1 使用者回饋與現況痛點
使用者在 LumiBase 中調高曝光（Exposure）滑桿時反映：
> 「在調高曝光的時候，看起來高光的部分調亮比較多，但是應該像 Lightcraft 是針對全部照片區域調亮。」

### 1.2 深入架構與數學根因分析 (Root Cause Analysis)
經深入分析 `/Users/tedyeng/VSCodeProjects/lightcraft` (Lightcraft) 與 LumiBase 目前之實作，發現本質差異在於**曝光套用的色彩空間階層與色調曲線的先後順序**：

#### A. Lightcraft 的做法 (物理場景線性空間 Scene-Linear)
1. **未映射光子域**：RAW 解碼後轉入無裁切、無 Gamma、未套用色調曲線的線性 Rec.2020 空間（`Rgb32f`，中性灰 Middle Grey 錨定於 0.18，浮點高光可達 2.0 ~ 8.0+）。
2. **均勻物理曝光增益**：
   $$\text{gain} = 2^{\text{exposure}}, \quad c = c_{\text{linear}} \times \text{gain}, \quad \log\_l = \log_2(\text{lum} / 0.18) + \text{exposure}$$
   在對數空間中，暗部、中間調、高光**均勻平移相同的 EV 檔位**（例如 $+1.0\text{ EV}$）。
3. **曝光後才過 Tone Map（肩部保護）**：
   $$\text{ToneMap}(y) = y \frac{1 + y / w_l^2}{1 + y} \quad (w_l = 0.18 \times 2^{2.9} \approx 1.343)$$
   當曝光調高時，暗部與中灰由於處於曲線陡峭區，在螢幕感知亮度上獲得自然充足的抬升；而暴增的高光數值進入了 $\frac{1}{1+y}$ 的肩膀（Shoulder）緩衝區，被優雅平滑地壓制在 1.0 以內，絕不硬性死白。同時觸發高光漂白（Specular Desaturation），自然泛白無色偏。

#### B. LumiBase 目前的做法 (顯示參考空間 Display-Referred)
1. **預覽快取已被 Apple 烘焙色調曲線**：在 `RAWImageLoader.swift` 中，解碼快取時設置 `boostAmount = 1.0`，Apple `CIRAWFilter` 已經將 S 曲線與對比度套用至 `baseCIImage`。
2. **直接線性倍率硬乘**：在 `AdobeColorPipeline.swift` 中，拖動滑桿時直接使用 Apple 的 `CIExposureAdjust`：
   $$\text{Output} = \text{Input} \times 2^{\Delta EV}$$
3. **數學上的災難：$T(x) \times 2^{EV}$ 而非 $T(x \times 2^{EV})$**：
   - 暗部（原本數值約 `0.03`）：$0.03 \times 2.0 = 0.06$，絕對亮度只增加了 `0.03`，視覺感受**暗部幾乎沒有被提亮**。
   - 中灰（原本數值約 `0.35`）：$0.35 \times 2.0 = 0.70$。
   - 高光（原本數值約 `0.65`）：$0.65 \times 2.0 = 1.30 \to 1.0$（直接撞牆截斷死白），視覺感受**高光暴增過曝**。
   - 若使用者未調整其他高光陰影滑桿，後面根本沒有任何 Tone Curve 保護。
4. **預覽與匯出不一致**：`PhotoExportService` 在 RAW 匯出時設定 `rawFilter.exposure = ev`，而即時預覽卻是 `rawFilter.exposure = 0.0` 外掛 `CIExposureAdjust`，導致預覽與匯出成像嚴重脫節。

---

## 2. 目標 (Objectives)

1. **光學均勻提亮 (Optical Uniform Exposure)**：
   調高曝光時，全圖暗部、中灰、高光按攝影光學對數均勻感光提亮，重現「鏡頭多進光 1 檔」的自然視覺。
2. **高光肩部保護與自然滾降 (Highlight Shoulder Rolloff)**：
   依循 Lightcraft 與 Adobe Camera Raw PV2012 的 Reinhard Filmic 曲線機制，在曝光拉高時高光自然滑入肩部壓縮，並具備高光漂白去飽和，保留雲朵細節與肌膚高光質感，徹底告別過曝死白。
3. **即時 120fps 滑桿流暢度**：
   設計高效能 Metal / Core Image 核心（`OpticalExposureKernel`），在 Apple Silicon GPU 上單影格耗時 < 1ms，確保拖動曝光滑桿極致順暢。
4. **預覽與匯出管線統一**：
   確保 Viewport 預覽與 `PhotoExportService` 匯出成品之曝光色彩表現嚴格一致。

---

## 3. 架構設計與實作規劃 (Architecture & Implementation Plan)

### 3.1 設計專屬光學曝光著色器：`OpticalExposureKernel`

在 `LumiBase/Services/Image/` 中新增光學曝光著色器（或擴充至核心管線）：

```metal
// CIColorKernel: opticalExposure
kernel vec4 opticalExposure(__sample s, float ev, float whiteEV) {
    vec3 c = max(s.rgb, vec3(0.0));
    
    // 1. 若無曝光調整，直接穿透
    if (abs(ev) < 0.001) {
        return s;
    }
    
    // 2. 轉入近似線性物理空間 (Linearize display values)
    // sRGB 逆轉移函式還原線性光
    vec3 lo = c / 12.92;
    vec3 hi = pow((c + vec3(0.055)) / 1.055, vec3(2.4));
    vec3 lin = mix(hi, lo, step(c, vec3(0.04045)));
    
    // 3. 施加光學曝光增益 (Optical gain: 2^EV)
    float gain = pow(2.0, ev);
    vec3 c_exp = lin * gain;
    
    // 4. 計算曝光後亮度 (Rec.709 / sRGB 亮度加權)
    float y = max(dot(c_exp, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
    
    // 5. 延伸 Reinhard 色調映射曲線 (依據 whiteEV 動態白點滾降)
    // 基準中灰 GREY = 0.18, 白點 wl = 0.18 * 2^(whiteEV)
    float wl = 0.18 * pow(2.0, whiteEV);
    float o = y * (1.0 + y / (wl * wl)) / (1.0 + y);
    o = min(o, 1.0);
    
    // 依亮度比例縮放各通道
    vec3 toned = c_exp * (o / y);
    
    // 6. 高光漂白去飽和 (Specular desaturation & gamut compression)
    float mx = max(toned.r, max(toned.g, toned.b));
    if (mx > 1.0) {
        float t = clamp((mx - 1.0) / max(mx - o, 1e-6), 0.0, 1.0);
        toned = mix(toned, vec3(o), t);
    }
    
    // 7. 轉回顯示編碼空間
    vec3 dLo = toned * 12.92;
    vec3 dHi = 1.055 * pow(max(toned, vec3(0.0031308)), vec3(1.0 / 2.4)) - 0.055;
    vec3 outEnc = mix(dHi, dLo, step(toned, vec3(0.0031308)));
    
    return vec4(clamp(outEnc, 0.0, 1.0), s.a);
}
```

### 3.2 改造 `AdobeColorPipeline.swift`
將步驟 1 原本的 `CIExposureAdjust` 替換為 `OpticalExposureKernel`：
```swift
// 1. Optical Exposure Compensation (Lightcraft-grade Reinhard Shoulder)
let targetEV = xmp.exposure2012 ?? 0.0
let baseEV = Double(baseHolder?.baseExposure ?? 0.0)
let deltaEV = targetEV - baseEV
if abs(deltaEV) > 0.005 {
    let whites = Double(xmp.whites2012 ?? 0)
    // 依照白場調整動態白點 (與 Lightcraft 保持一致: 2.9 - 1.6 * (whites / 100))
    let whiteEV = 2.9 - 1.6 * (whites / 100.0)
    current = OpticalExposureKernel.apply(image: current, ev: Float(deltaEV), whiteEV: Float(whiteEV))
}
```

### 3.3 統一匯出與預覽管線 (`PhotoExportService.swift`)
- 檢查 `PhotoExportService.swift`：
  當使用 `OpticalExposureKernel` 後，預覽與匯出均能享受相同的高光肩部保護與全圖自然提亮。
- 確保無論是 RAW 還是 JPEG / HEIC，在 `AdobeColorPipeline` 均有一致的曝光表現。

---

## 4. 驗證與測試計畫 (Verification & Test Plan)

1. **單元測試 (`OpticalExposureTests.swift`)**：
   - 測試極端正向曝光（如 $+3.0\text{ EV}$、$+5.0\text{ EV}$）下，高光區域（純白邊緣）不會產生色彩溢出或偽影，最大值被良好約束在 $\le 1.0$。
   - 測試暗部（如 Luminance $0.05$）在 $+1.0\text{ EV}$ 下獲得充分且符合物理光學的光強抬升。
   - 測試單調性（Monotonicity）：隨著曝光值增加，全圖平均亮度嚴格單調遞增。
2. **側向對比（與 Lightcraft 基準比對）**：
   - 使用相同 RAW 相片在 Lightcraft 與 LumiBase 中同時設定 `Exposure = +1.5 EV`。
   - 檢視高光區（天空、雲層、反光部位）與陰影區（暗部細節），驗證高光未死白、全圖提亮感受一致。
3. **效能基準測試**：
   - 在 M4 / Apple Silicon 上驗證 2560px 預覽與全尺寸 4K 檢視，確保滑桿拖曳幀率維持 120fps。
