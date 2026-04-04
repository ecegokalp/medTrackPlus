# Pill Detection Accuracy — ML Kit Object Detection

## Configuration

| Parameter        | Value                  |
|------------------|------------------------|
| API              | ML Kit ObjectDetector  |
| Mode             | `DetectionMode.stream` |
| classifyObjects  | `true`                 |
| multipleObjects  | `false`                |
| Model            | Base (built-in)        |
| Resolution       | `ResolutionPreset.medium` |
| Image Format     | NV21                   |

## Test Protocol

1. Select pill type (Round / Oval / Capsule) in the test screen
2. Tap **Start Recording** — hold pill in front of the **back camera**
3. Move pill slowly: center, edges, near, far, rotated
4. Tap **Stop Recording**
5. Repeat for each pill type
6. Tap **Report** to view accuracy summary

## Expected Results (Base Model — No Custom TFLite)

> **Important:** ML Kit's base ObjectDetector is a generic model. It detects
> "objects" but does NOT have a "pill" class. Labels will be generic
> (e.g., "Food", "Home good", or index-based). Confidence reflects how sure
> the model is that *something* is there, not that it's specifically a pill.

### Round Pills
- **Detection rate:** High — compact shape, strong edges
- **Confidence range:** 0.50 – 0.85
- **Bounding box:** Tight, near-square aspect ratio
- **Notes:** Best detected on contrasting background (white pill on dark surface)

### Oval Pills
- **Detection rate:** High — similar to round, slightly elongated box
- **Confidence range:** 0.45 – 0.80
- **Bounding box:** Rectangular, width > height
- **Notes:** May lose detection at steep angles

### Capsule Pills
- **Detection rate:** Medium-High — elongated shape is less "object-like"
- **Confidence range:** 0.40 – 0.75
- **Bounding box:** Wider aspect ratio
- **Notes:** Two-tone capsules may slightly improve detection due to color contrast

## Limitations

| Limitation | Impact |
|------------|--------|
| No pill-specific class | Labels are generic; can't distinguish pill from similar small objects |
| Single object mode | Only tracks the most prominent object — hand may override pill |
| Lighting dependency | Low light significantly reduces confidence |
| Distance sensitivity | Pill must be 10-30 cm from camera for reliable detection |
| Background clutter | Busy backgrounds reduce accuracy |

## Recommendations for Production

1. **Custom TFLite model** — Train on pill dataset (round, oval, capsule, tablet) for
   pill-specific classification with >0.90 confidence
2. **`multipleObjects: true`** — Enable if hand + pill must both be tracked
3. **Confidence threshold** — Set minimum 0.50 for pill-detected state
4. **Combine with face detection** — Current pipeline already supports this via
   `CVFrameData.pillDetected` + `CVFrameData.faceDetected`

## How to Read the Report

The in-app report (tap the chart icon) shows per pill type:

- **Detections** — Total frames where an object was found
- **Avg / Min / Max Confidence** — Statistical spread
- **Avg Box Size** — Average bounding box dimensions in pixels
- **Labels** — Which generic labels ML Kit assigned and how often